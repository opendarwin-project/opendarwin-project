//! Minimal Info.plist XML parser.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParseError {
    MalformedXml,
    MissingExecutable,
    MissingIdentifier,
    UnsupportedPackageType,
}
#[derive(Clone, Copy)]
pub struct Info {
    pub bundle_identifier: [u8; 64],
    pub bundle_identifier_len: usize,
    pub executable: [u8; 64],
    pub executable_len: usize,
    pub package_type: [u8; 16],
    pub package_type_len: usize,
    pub bundle_name: [u8; 64],
    pub bundle_name_len: usize,
}

impl Default for Info {
    fn default() -> Self {
        Self {
            bundle_identifier: [0; 64],
            bundle_identifier_len: 0,
            executable: [0; 64],
            executable_len: 0,
            package_type: [0; 16],
            package_type_len: 0,
            bundle_name: [0; 64],
            bundle_name_len: 0,
        }
    }
}

impl Info {
    pub fn bundle_id(&self) -> &str {
        core::str::from_utf8(&self.bundle_identifier[..self.bundle_identifier_len]).unwrap_or("")
    }

    pub fn exe_name(&self) -> &str {
        core::str::from_utf8(&self.executable[..self.executable_len]).unwrap_or("")
    }

    pub fn pkg_type(&self) -> &str {
        core::str::from_utf8(&self.package_type[..self.package_type_len]).unwrap_or("")
    }
}

pub fn parse_info_plist(bytes: &[u8]) -> Result<Info, ParseError> {
    let mut info = Info::default();
    let text = core::str::from_utf8(bytes).map_err(|_| ParseError::MalformedXml)?;

    let extract_key = |key_name: &str| -> Option<&str> {
        let needle = match key_name {
            "CFBundleIdentifier" => "<key>CFBundleIdentifier</key>",
            "CFBundleExecutable" => "<key>CFBundleExecutable</key>",
            "CFBundlePackageType" => "<key>CFBundlePackageType</key>",
            "CFBundleName" => "<key>CFBundleName</key>",
            _ => return None,
        };

        if let Some(pos) = text.find(needle) {
            let after_key = &text[pos + needle.len()..];
            if let Some(str_start) = after_key.find("<string>") {
                let after_str = &after_key[str_start + 8..];
                if let Some(str_end) = after_str.find("</string>") {
                    return Some(&after_str[..str_end]);
                }
            }
        }
        None
    };

    if let Some(id) = extract_key("CFBundleIdentifier") {
        let n = id.len().min(info.bundle_identifier.len());
        info.bundle_identifier[..n].copy_from_slice(&id.as_bytes()[..n]);
        info.bundle_identifier_len = n;
    }
    if let Some(exe) = extract_key("CFBundleExecutable") {
        let n = exe.len().min(info.executable.len());
        info.executable[..n].copy_from_slice(&exe.as_bytes()[..n]);
        info.executable_len = n;
    }
    if let Some(pkg) = extract_key("CFBundlePackageType") {
        let n = pkg.len().min(info.package_type.len());
        info.package_type[..n].copy_from_slice(&pkg.as_bytes()[..n]);
        info.package_type_len = n;
    }
    if let Some(name) = extract_key("CFBundleName") {
        let n = name.len().min(info.bundle_name.len());
        info.bundle_name[..n].copy_from_slice(&name.as_bytes()[..n]);
        info.bundle_name_len = n;
    }

    if info.pkg_type() != "KEXT" {
        return Err(ParseError::UnsupportedPackageType);
    }
    if info.bundle_identifier_len == 0 {
        return Err(ParseError::MissingIdentifier);
    }
    if info.executable_len == 0 {
        return Err(ParseError::MissingExecutable);
    }

    Ok(info)
}
