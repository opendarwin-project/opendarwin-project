//! Configurable AIR / macOS target versions for metallib emission.
//!
//! Defaults match current Xcode Metal 4.1 goldens (AIR 2.9 / macOS 27). Override
//! via environment variables so host Metal tests work on older runners (e.g.
//! GitHub Actions macOS 26 / AIR 2.8):
//!
//! - `METALC_MACOS_MAJOR` — macOS major in the triple and SDK Version metadata
//! - `METALC_AIR_VERSION` — `major.minor` or `major.minor.patch` (e.g. `2.8`)
//!
//! When unset, [`AirTarget::resolve`] picks a preset from the host macOS version
//! on Apple platforms, then falls back to [`AirTarget::MACOS27_AIR29`].

use std::sync::OnceLock;

/// AIR LLVM dialect version + macOS deployment target used in triples / metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AirTarget {
    pub macos_major: u32,
    pub macos_minor: u32,
    pub air_major: u32,
    pub air_minor: u32,
    pub air_patch: u32,
}

impl AirTarget {
    /// Xcode Metal 4.1 golden target (AIR 2.9 / macOS 27).
    pub const MACOS27_AIR29: Self = Self {
        macos_major: 27,
        macos_minor: 0,
        air_major: 2,
        air_minor: 9,
        air_patch: 0,
    };

    /// GitHub Actions / older SDK target (AIR 2.8 / macOS 26).
    pub const MACOS26_AIR28: Self = Self {
        macos_major: 26,
        macos_minor: 0,
        air_major: 2,
        air_minor: 8,
        air_patch: 0,
    };

    /// AIR LLVM version encoded in the triple (`v29` ← AIR 2.9).
    pub fn air_llvm_version(self) -> u32 {
        self.air_major * 10 + self.air_minor
    }

    pub fn air_version(self) -> (u32, u32, u32) {
        (self.air_major, self.air_minor, self.air_patch)
    }

    pub fn macos_version(self) -> (u32, u32, u32) {
        (self.macos_major, self.macos_minor, 0)
    }

    /// `air64_v{N}-apple-macosx{major}.{minor}.0`
    pub fn triple(self) -> String {
        format!(
            "air64_v{}-apple-macosx{}.{}.0",
            self.air_llvm_version(),
            self.macos_major,
            self.macos_minor
        )
    }

    /// Resolve the active target: env overrides → host macOS preset → default.
    pub fn resolve() -> Self {
        static RESOLVED: OnceLock<AirTarget> = OnceLock::new();
        *RESOLVED.get_or_init(Self::resolve_uncached)
    }

    fn resolve_uncached() -> Self {
        if let Some(t) = Self::from_env() {
            return t;
        }
        if let Some(major) = host_macos_major() {
            return Self::for_macos_major(major);
        }
        Self::MACOS27_AIR29
    }

    /// Preset matching a macOS major version.
    pub fn for_macos_major(macos_major: u32) -> Self {
        match macos_major {
            ..=26 => Self::MACOS26_AIR28,
            _ => Self::MACOS27_AIR29,
        }
    }

    fn from_env() -> Option<Self> {
        let macos_major = match std::env::var("METALC_MACOS_MAJOR") {
            Ok(s) => Some(s.parse::<u32>().ok()?),
            Err(_) => None,
        };
        let air = match std::env::var("METALC_AIR_VERSION") {
            Ok(s) => Some(parse_air_version(&s)?),
            Err(_) => None,
        };

        match (macos_major, air) {
            (None, None) => None,
            (Some(macos_major), Some((air_major, air_minor, air_patch))) => Some(Self {
                macos_major,
                macos_minor: 0,
                air_major,
                air_minor,
                air_patch,
            }),
            (Some(macos_major), None) => Some(Self::for_macos_major(macos_major)),
            (None, Some((air_major, air_minor, air_patch))) => {
                let mut t = Self::for_air_minor(air_minor);
                t.air_major = air_major;
                t.air_minor = air_minor;
                t.air_patch = air_patch;
                Some(t)
            }
        }
    }

    fn for_air_minor(air_minor: u32) -> Self {
        match air_minor {
            ..=8 => Self::MACOS26_AIR28,
            _ => Self::MACOS27_AIR29,
        }
    }
}

fn parse_air_version(s: &str) -> Option<(u32, u32, u32)> {
    let mut parts = s.trim().split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next().map(|p| p.parse().ok()).unwrap_or(Some(0))?;
    Some((major, minor, patch))
}

fn host_macos_major() -> Option<u32> {
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("sw_vers")
            .arg("-productVersion")
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let version = String::from_utf8_lossy(&output.stdout);
        version.trim().split('.').next()?.parse().ok()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// Default AIR datalayout string (unchanged across recent AIR versions).
pub const AIR_DATALAYOUT: &str = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triple_encoding() {
        assert_eq!(
            AirTarget::MACOS27_AIR29.triple(),
            "air64_v29-apple-macosx27.0.0"
        );
        assert_eq!(
            AirTarget::MACOS26_AIR28.triple(),
            "air64_v28-apple-macosx26.0.0"
        );
    }

    #[test]
    fn parse_versions() {
        assert_eq!(parse_air_version("2.8"), Some((2, 8, 0)));
        assert_eq!(parse_air_version("2.9.0"), Some((2, 9, 0)));
    }
}
