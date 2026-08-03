#!/usr/bin/env nu
# Build IOKit.framework (universal arm64 + arm64e) from the no_std Rust crate.
# Usage:
#   nu tools/build_iokit_framework.nu        # -> target/iokit-framework/IOKit.framework
#   DYLD_FRAMEWORK_PATH=$PWD/target/iokit-framework tools/iokit_smoke

# Abort the whole script on the first failing external command.
$env.config.error_style = "fancy"
$env.config.show_banner = false

let root = ($env.FILE_PWD | path expand | path dirname)
let out  = ($root | path join target frameworks)
let vers = ($out | path join IOKit.framework Versions A)
let build_std = "core,alloc,panic_abort"
let targets = ["aarch64-apple-darwin", "arm64e-apple-darwin"]

def check [] {
    if $env.LAST_EXIT_CODE != 0 {
        error make { msg: "command failed, aborting" }
    }
}

cd $root

for t in $targets {
    print ("==> building " + $t + " (release, build-std=" + $build_std + ")")
    cargo build -p iokit --release $"-Zbuild-std=($build_std)" --target $t
    check
}

let arm64  = $root | path join target aarch64-apple-darwin release libIOKit.dylib
let arm64e = $root | path join target arm64e-apple-darwin release libIOKit.dylib

rm -rf $out
mkdir $vers

lipo -create $arm64 $arm64e -output ($vers | path join IOKit)
check

# dyld resolves frameworks by install_name; mirror real IOKit.framework's layout.
install_name_tool -id "@rpath/IOKit.framework/Versions/A/IOKit" ($vers | path join IOKit)
check
ln -sfn Versions/A/IOKit ($out | path join IOKit.framework IOKit)
ln -sfn Versions/A       ($out | path join IOKit.framework Current)
ln -sfn A                ($out | path join IOKit.framework Versions Current)

let plist = $'<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>IOKit</string>
    <key>CFBundleIdentifier</key><string>org.opendarwin.IOKit</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
</dict>
</plist>
'
$plist | save -f ($out | path join IOKit.framework Info.plist)

print $"==> built ($out)/IOKit.framework"
lipo -info ($vers | path join IOKit)
otool -L ($vers | path join IOKit) | lines | first 4
