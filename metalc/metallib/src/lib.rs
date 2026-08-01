//! MTLB metallib container format (Apple Metal library).
//!
//! Layout (from metal-ir-pipeline / floor metallib-dis reverse engineering):
//! ```text
//! [0:88]   MTLB header (magic + platform + filesize + 4 section descriptors)
//! [...]    Section 0: entry headers (u32 count + per-entry size+tags)
//! [gap]    2× ENDT per entry (not counted in section 0 size)
//! [...]    Section 1: function list stub (u32(4) + ENDT)
//! [...]    Section 2: public metadata stub (u32(4) + ENDT)
//! [...]    Section 3: wrapped bitcode (0x0B17C0DE + raw LLVM/AIR bitcode)
//! ```

use sha2::{Digest, Sha256};
use thiserror::Error;

pub const MTLB_MAGIC: &[u8; 4] = b"MTLB";
pub const BITCODE_WRAPPER_MAGIC: u32 = 0x0B17C0DE;
pub const HEADER_SIZE: usize = 88;

/// macOS platform byte used in the MTLB header.
pub const PLATFORM_MACOS: u8 = 0x81;

#[derive(Debug, Clone)]
pub struct MetallibOptions {
    pub platform: u8,
    pub os_major: u16,
    pub os_minor: u16,
    pub os_patch: u16,
    pub metal_major: u16,
    pub metal_minor: u16,
    pub air_major: u16,
    pub air_minor: u16,
}

impl Default for MetallibOptions {
    fn default() -> Self {
        // Match current Xcode Metal 4.1 / AIR 2.9 goldens on macOS 27 tooling.
        Self {
            platform: PLATFORM_MACOS,
            os_major: 27,
            os_minor: 0,
            os_patch: 0,
            metal_major: 4,
            metal_minor: 1,
            air_major: 2,
            air_minor: 9,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EntryType {
    Vertex = 0,
    Fragment = 1,
    Kernel = 2,
    Object = 5,
    Mesh = 6,
}

#[derive(Debug, Clone)]
pub struct MetallibEntry {
    pub name: String,
    pub entry_type: EntryType,
}

#[derive(Debug, Error)]
pub enum MetallibError {
    #[error("invalid MTLB magic")]
    BadMagic,
    #[error("truncated metallib")]
    Truncated,
    #[error("invalid bitcode wrapper")]
    BadWrapper,
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

fn write_u16(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn write_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn write_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_le_bytes());
}

fn write_tag(out: &mut Vec<u8>, name: &[u8; 4], payload: &[u8]) {
    out.extend_from_slice(name);
    write_u16(out, payload.len() as u16);
    out.extend_from_slice(payload);
}

/// Wrap raw LLVM/AIR bitcode in Apple's 20-byte bitcode wrapper.
pub fn wrap_bitcode(bc: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(20 + bc.len());
    write_u32(&mut out, BITCODE_WRAPPER_MAGIC);
    write_u32(&mut out, 0); // version
    write_u32(&mut out, 20); // offset to bitcode
    write_u32(&mut out, bc.len() as u32);
    write_u32(&mut out, 0xFFFF_FFFF); // CPU type
    out.extend_from_slice(bc);
    out
}

/// Unwrap Apple's bitcode wrapper, returning the raw bitcode payload.
pub fn unwrap_bitcode(wrapped: &[u8]) -> Result<Vec<u8>, MetallibError> {
    if wrapped.len() < 20 {
        return Err(MetallibError::BadWrapper);
    }
    let magic = u32::from_le_bytes(wrapped[0..4].try_into().unwrap());
    if magic != BITCODE_WRAPPER_MAGIC {
        return Err(MetallibError::BadWrapper);
    }
    let offset = u32::from_le_bytes(wrapped[8..12].try_into().unwrap()) as usize;
    let size = u32::from_le_bytes(wrapped[12..16].try_into().unwrap()) as usize;
    if offset + size > wrapped.len() {
        return Err(MetallibError::Truncated);
    }
    Ok(wrapped[offset..offset + size].to_vec())
}

fn build_entry_tags(
    name: &str,
    hash: &[u8; 32],
    wrapped_size: u64,
    opts: &MetallibOptions,
    entry_type: EntryType,
) -> Vec<u8> {
    let mut tags = Vec::new();
    let mut name_payload = name.as_bytes().to_vec();
    name_payload.push(0);
    write_tag(&mut tags, b"NAME", &name_payload);
    write_tag(&mut tags, b"TYPE", &[entry_type as u8]);
    write_tag(&mut tags, b"HASH", hash);
    let mut mdsz = Vec::new();
    write_u64(&mut mdsz, wrapped_size);
    write_tag(&mut tags, b"MDSZ", &mdsz);
    let mut offt = Vec::new();
    write_u64(&mut offt, 0);
    write_u64(&mut offt, 0);
    write_u64(&mut offt, 0);
    write_tag(&mut tags, b"OFFT", &offt);
    let mut vers = Vec::new();
    write_u16(&mut vers, opts.air_major);
    write_u16(&mut vers, opts.air_minor);
    write_u16(&mut vers, opts.metal_major);
    write_u16(&mut vers, opts.metal_minor);
    write_tag(&mut tags, b"VERS", &vers);
    tags
}

/// Pack one or more AIR bitcode blobs into a `.metallib`.
///
/// For the MVP, all entries share a single bitcode module (`bitcode`).
pub fn write_metallib(
    bitcode: &[u8],
    entries: &[MetallibEntry],
    opts: &MetallibOptions,
) -> Vec<u8> {
    let wrapped = wrap_bitcode(bitcode);
    let hash: [u8; 32] = Sha256::digest(&wrapped).into();

    let mut sec0 = Vec::new();
    write_u32(&mut sec0, entries.len() as u32);

    let mut endt_gap = Vec::new();
    for entry in entries {
        let tags = build_entry_tags(
            &entry.name,
            &hash,
            wrapped.len() as u64,
            opts,
            entry.entry_type,
        );
        // entry_size includes two trailing ENDT markers written in the gap.
        let entry_size = (tags.len() + 8) as u32;
        write_u32(&mut sec0, entry_size);
        sec0.extend_from_slice(&tags);
        endt_gap.extend_from_slice(b"ENDT");
        endt_gap.extend_from_slice(b"ENDT");
    }

    let mut sec12 = Vec::new();
    write_u32(&mut sec12, 4);
    sec12.extend_from_slice(b"ENDT");

    let sec0_offset = HEADER_SIZE as u64;
    let sec0_size = sec0.len() as u64;
    let gap_size = endt_gap.len() as u64;
    let sec1_offset = sec0_offset + sec0_size + gap_size;
    let sec1_size = sec12.len() as u64;
    let sec2_offset = sec1_offset + sec1_size;
    let sec2_size = sec12.len() as u64;
    let sec3_offset = sec2_offset + sec2_size;
    let sec3_size = wrapped.len() as u64;
    let total_size = sec3_offset + sec3_size;

    let mut out = Vec::with_capacity(total_size as usize);
    out.extend_from_slice(MTLB_MAGIC);

    // Platform header (12 bytes) — layout matched to xcrun metallib output:
    //   01 80 02 00 09 00 00 <platform> <os_major> 00 00 00
    let mut platform = [0u8; 12];
    platform[0] = 0x01;
    platform[1] = 0x80;
    platform[2] = 0x02;
    platform[3] = 0x00;
    platform[4] = 0x09;
    platform[5] = 0x00;
    platform[6] = 0x00;
    platform[7] = opts.platform;
    platform[8] = (opts.os_major & 0xff) as u8;
    out.extend_from_slice(&platform);

    write_u64(&mut out, total_size);
    write_u64(&mut out, sec0_offset);
    write_u64(&mut out, sec0_size);
    write_u64(&mut out, sec1_offset);
    write_u64(&mut out, sec1_size);
    write_u64(&mut out, sec2_offset);
    write_u64(&mut out, sec2_size);
    write_u64(&mut out, sec3_offset);
    write_u64(&mut out, sec3_size);

    out.extend_from_slice(&sec0);
    out.extend_from_slice(&endt_gap);
    out.extend_from_slice(&sec12);
    out.extend_from_slice(&sec12);
    out.extend_from_slice(&wrapped);
    out
}

#[derive(Debug, Clone)]
pub struct ParsedMetallib {
    pub file_size: u64,
    pub section_offsets: [(u64, u64); 4],
    pub entries: Vec<ParsedEntry>,
    pub wrapped_bitcode: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ParsedEntry {
    pub name: String,
    pub entry_type: u8,
    pub hash: [u8; 32],
    pub mdsz: u64,
    pub air_major: u16,
    pub air_minor: u16,
    pub metal_major: u16,
    pub metal_minor: u16,
}

/// Parse a metallib enough for round-trip / golden tests.
pub fn parse_metallib(data: &[u8]) -> Result<ParsedMetallib, MetallibError> {
    if data.len() < HEADER_SIZE {
        return Err(MetallibError::Truncated);
    }
    if &data[0..4] != MTLB_MAGIC {
        return Err(MetallibError::BadMagic);
    }
    let file_size = u64::from_le_bytes(data[16..24].try_into().unwrap());
    let mut section_offsets = [(0u64, 0u64); 4];
    for (i, section_offset) in section_offsets.iter_mut().enumerate() {
        let base = 24 + i * 16;
        let off = u64::from_le_bytes(data[base..base + 8].try_into().unwrap());
        let sz = u64::from_le_bytes(data[base + 8..base + 16].try_into().unwrap());
        *section_offset = (off, sz);
    }

    let (sec0_off, sec0_sz) = section_offsets[0];
    let sec0_end = (sec0_off + sec0_sz) as usize;
    if sec0_end > data.len() {
        return Err(MetallibError::Truncated);
    }
    let sec0 = &data[sec0_off as usize..sec0_end];
    if sec0.len() < 4 {
        return Err(MetallibError::Truncated);
    }
    let count = u32::from_le_bytes(sec0[0..4].try_into().unwrap()) as usize;
    let mut entries = Vec::new();
    let mut p = 4usize;
    for _ in 0..count {
        if p + 4 > sec0.len() {
            return Err(MetallibError::Truncated);
        }
        let entry_size = u32::from_le_bytes(sec0[p..p + 4].try_into().unwrap()) as usize;
        p += 4;
        // Tags in section 0 exclude the two ENDTs accounted in entry_size.
        let tags_len = entry_size.saturating_sub(8);
        if p + tags_len > sec0.len() {
            return Err(MetallibError::Truncated);
        }
        let tags = &sec0[p..p + tags_len];
        p += tags_len;
        entries.push(parse_entry_tags(tags)?);
    }

    let (sec3_off, sec3_sz) = section_offsets[3];
    let sec3_end = (sec3_off + sec3_sz) as usize;
    if sec3_end > data.len() {
        return Err(MetallibError::Truncated);
    }
    let wrapped_bitcode = data[sec3_off as usize..sec3_end].to_vec();

    Ok(ParsedMetallib {
        file_size,
        section_offsets,
        entries,
        wrapped_bitcode,
    })
}

fn parse_entry_tags(tags: &[u8]) -> Result<ParsedEntry, MetallibError> {
    let mut name = String::new();
    let mut entry_type = 2u8;
    let mut hash = [0u8; 32];
    let mut mdsz = 0u64;
    let mut air_major = 0u16;
    let mut air_minor = 0u16;
    let mut metal_major = 0u16;
    let mut metal_minor = 0u16;

    let mut i = 0usize;
    while i + 4 <= tags.len() {
        let tag = &tags[i..i + 4];
        if tag == b"ENDT" {
            i += 4;
            continue;
        }
        if i + 6 > tags.len() {
            break;
        }
        let len = u16::from_le_bytes(tags[i + 4..i + 6].try_into().unwrap()) as usize;
        i += 6;
        if i + len > tags.len() {
            return Err(MetallibError::Truncated);
        }
        let payload = &tags[i..i + len];
        match tag {
            b"NAME" => {
                name = String::from_utf8_lossy(payload)
                    .trim_end_matches('\0')
                    .to_string();
            }
            b"TYPE" => {
                if !payload.is_empty() {
                    entry_type = payload[0];
                }
            }
            b"HASH" => {
                if payload.len() >= 32 {
                    hash.copy_from_slice(&payload[..32]);
                }
            }
            b"MDSZ" => {
                if payload.len() >= 8 {
                    mdsz = u64::from_le_bytes(payload[..8].try_into().unwrap());
                }
            }
            b"VERS" if payload.len() >= 8 => {
                air_major = u16::from_le_bytes(payload[0..2].try_into().unwrap());
                air_minor = u16::from_le_bytes(payload[2..4].try_into().unwrap());
                metal_major = u16::from_le_bytes(payload[4..6].try_into().unwrap());
                metal_minor = u16::from_le_bytes(payload[6..8].try_into().unwrap());
            }
            _ => {}
        }
        i += len;
    }

    Ok(ParsedEntry {
        name,
        entry_type,
        hash,
        mdsz,
        air_major,
        air_minor,
        metal_major,
        metal_minor,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn testdata(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../testdata")
            .join(name)
    }

    #[test]
    fn parse_golden_metallib() {
        let data = std::fs::read(testdata("add_one.metallib")).expect("golden metallib");
        let parsed = parse_metallib(&data).expect("parse");
        assert_eq!(parsed.file_size, data.len() as u64);
        assert_eq!(parsed.entries.len(), 1);
        assert_eq!(parsed.entries[0].name, "add_one");
        assert_eq!(parsed.entries[0].entry_type, EntryType::Kernel as u8);
        assert_eq!(parsed.entries[0].air_major, 2);
        assert_eq!(parsed.entries[0].air_minor, 9);
        assert_eq!(parsed.entries[0].metal_major, 4);
        assert_eq!(parsed.entries[0].metal_minor, 1);
        let bc = unwrap_bitcode(&parsed.wrapped_bitcode).expect("unwrap");
        assert_eq!(&bc[0..2], b"BC");
    }

    #[test]
    fn repack_golden_bitcode() {
        let golden = std::fs::read(testdata("add_one.metallib")).unwrap();
        let parsed = parse_metallib(&golden).unwrap();
        let bc = unwrap_bitcode(&parsed.wrapped_bitcode).unwrap();
        let opts = MetallibOptions {
            air_major: parsed.entries[0].air_major,
            air_minor: parsed.entries[0].air_minor,
            metal_major: parsed.entries[0].metal_major,
            metal_minor: parsed.entries[0].metal_minor,
            ..MetallibOptions::default()
        };
        let packed = write_metallib(
            &bc,
            &[MetallibEntry {
                name: "add_one".into(),
                entry_type: EntryType::Kernel,
            }],
            &opts,
        );
        let reparsed = parse_metallib(&packed).unwrap();
        assert_eq!(reparsed.entries[0].name, "add_one");
        assert_eq!(reparsed.entries[0].entry_type, 2);
        assert_eq!(unwrap_bitcode(&reparsed.wrapped_bitcode).unwrap(), bc);
    }
}
