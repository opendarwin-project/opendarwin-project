#!/usr/bin/env bash
set -euo pipefail

# Build libSystem (libSystem.B.dylib) and IOKit.framework (universal arm64 + arm64e)
# from the no_std Rust crates using the Mach-O mold linker.
# Usage:
#   ./tools/build_frameworks.sh        # -> target/frameworks/
#   DYLD_FRAMEWORK_PATH=$PWD/target/frameworks tools/iokit_smoke

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/target/frameworks"
vers="$out/IOKit.framework/Versions/A"
build_std="core,alloc,panic_abort"
targets=("aarch64-apple-darwin" "arm64e-apple-darwin")

LIPO="${LIPO:-$(command -v lipo 2>/dev/null || command -v llvm-lipo 2>/dev/null || echo lipo)}"
INSTALL_NAME_TOOL="${INSTALL_NAME_TOOL:-$(command -v install_name_tool 2>/dev/null || command -v llvm-install-name-tool 2>/dev/null || echo install_name_tool)}"
OTOOL="${OTOOL:-$(command -v otool 2>/dev/null || command -v llvm-otool 2>/dev/null || echo otool)}"
MOLD="${MOLD:-$root/../mold/build/mold}"

if [ ! -x "$MOLD" ]; then
    MOLD="$(command -v mold || echo "$MOLD")"
fi

cd "$root"

for t in "${targets[@]}"; do
    echo "==> building libsystem for $t (release, build-std=$build_std)"
    RUSTFLAGS="-Clink-arg=--target=$t -Clink-arg=-fuse-ld=$MOLD -Clink-arg=-nodefaultlibs -Clink-arg=-install_name -Clink-arg=/usr/lib/libSystem.B.dylib" \
        cargo build -p libsystem --release -Zbuild-std="$build_std" --target "$t"

    echo "==> building iokit for $t (release, build-std=$build_std)"
    RUSTFLAGS="-Clink-arg=--target=$t -Clink-arg=-fuse-ld=$MOLD -Clink-arg=-L$root/target/$t/release" \
        cargo build -p iokit --release -Zbuild-std="$build_std" --target "$t"
done

libsystem_arm64="$root/target/aarch64-apple-darwin/release/libSystem.dylib"
libsystem_arm64e="$root/target/arm64e-apple-darwin/release/libSystem.dylib"

iokit_arm64="$root/target/aarch64-apple-darwin/release/libIOKit.dylib"
iokit_arm64e="$root/target/arm64e-apple-darwin/release/libIOKit.dylib"

rm -rf "$out"
mkdir -p "$vers"

# Universal libSystem.B.dylib
"$LIPO" -create "$libsystem_arm64" "$libsystem_arm64e" -output "$out/libSystem.B.dylib"
"$INSTALL_NAME_TOOL" -id "/usr/lib/libSystem.B.dylib" "$out/libSystem.B.dylib"
ln -sfn libSystem.B.dylib "$out/libSystem.dylib"

# Universal IOKit.framework
"$LIPO" -create "$iokit_arm64" "$iokit_arm64e" -output "$vers/IOKit"

# dyld resolves frameworks by install_name; mirror real IOKit.framework's layout.
"$INSTALL_NAME_TOOL" -id "@rpath/IOKit.framework/Versions/A/IOKit" "$vers/IOKit"
ln -sfn Versions/A/IOKit "$out/IOKit.framework/IOKit"
ln -sfn Versions/A       "$out/IOKit.framework/Current"
ln -sfn A                "$out/IOKit.framework/Versions/Current"

cat <<'EOF' > "$out/IOKit.framework/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
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
EOF

echo "==> built $out/libSystem.B.dylib and $out/IOKit.framework"
"$LIPO" -info "$out/libSystem.B.dylib"
"$OTOOL" -L "$out/libSystem.B.dylib" | head -n 4
"$LIPO" -info "$vers/IOKit"
"$OTOOL" -L "$vers/IOKit" | head -n 4
