#!/bin/bash
# Build all unmodified Theseus Swift + all app/*.swift + Bundle.module as one object.
# Usage: bash tools/build-theseus.sh [output-directory [ThemeBoard.app-directory]]
# TB_BUILD_ARCH=arm64|arm64e chooses the actual Swift target (default arm64).
# Called by ci-build.sh; this helper does not link, sign, or package the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "error: $*" >&2; exit 1; }
[ "$#" -le 2 ] || fail "Usage: bash tools/build-theseus.sh [output-directory [ThemeBoard.app-directory]]"
if [ "$(uname -s)" != "Darwin" ]; then
  fail "Original Theseus Swift/Metal requires macOS with full Xcode and the iPhoneOS SDK. Run bash tools/ci-build.sh on macOS or manually dispatch .github/workflows/build.yml; Linux/iSH cannot build this app."
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required for the pinned vendor manifest verifier."
[ -f tools/verify_theseus.py ] || fail "Missing tools/verify_theseus.py; do not build without pinned source verification."
python3 tools/verify_theseus.py --root "$ROOT"
command -v xcrun >/dev/null 2>&1 || fail "Install full Xcode and select it with xcode-select before building."
for tool in swiftc metal metallib; do
  xcrun --sdk iphoneos --find "$tool" >/dev/null || fail "Xcode iPhoneOS tool unavailable: $tool"
done
xcrun --sdk iphoneos metal --version >/dev/null 2>&1 || \
  fail "Metal compiler unavailable. Install the Xcode Metal Toolchain (on Xcode 26+: xcodebuild -downloadComponent MetalToolchain)."

SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
TB_BUILD_ARCH="${TB_BUILD_ARCH:-arm64}"
case "$TB_BUILD_ARCH" in
  arm64|arm64e) ;;
  *) fail "TB_BUILD_ARCH must be arm64 or arm64e (no header architecture rewriting)." ;;
esac
OUT="${1:-$ROOT/build/ci/$TB_BUILD_ARCH}"
APP="${2:-$OUT/ThemeBoard.app}"
VENDOR="$ROOT/Vendor/Theseus/Sources/Theseus"
PIN="71ca1c127a4e7fe3387361f160c4890dbd427f66"
[ -d "$VENDOR" ] || fail "Missing $VENDOR; vendor the complete original Sources/Theseus at $PIN."
for required in app/TBTheseusDock.swift app/TBTheseusDock.h \
                app/TBTheseusMaterial.swift app/TBTheseusMaterial.h \
                Integration/TheseusBundle.swift Vendor/Theseus/Package.swift \
                Vendor/Theseus/LICENSE Vendor/Theseus/NOTICE Vendor/Theseus/UPSTREAM.json; do
  [ -f "$required" ] || fail "Missing $required; both bridges, Bundle.module and complete vendor metadata are required."
done

# Bash 3.2-compatible arrays preserve paths with spaces; no SPM-generated header.
SWIFT_SOURCES=()
while IFS= read -r -d '' source; do
  SWIFT_SOURCES+=("$source")
done < <(find "$VENDOR" -type f -name '*.swift' -print0)
[ "${#SWIFT_SOURCES[@]}" -gt 0 ] || fail "No vendored Theseus Swift sources found."
shopt -s nullglob
APP_SWIFT=("$ROOT"/app/*.swift)
[ "${#APP_SWIFT[@]}" -gt 0 ] || fail "No App Swift sources found."
SWIFT_SOURCES+=("${APP_SWIFT[@]}" "$ROOT/Integration/TheseusBundle.swift")
METAL_SOURCES=()
while IFS= read -r -d '' source; do
  METAL_SOURCES+=("$source")
done < <(find "$VENDOR" -type f -name '*.metal' -print0)
[ "${#METAL_SOURCES[@]}" -gt 0 ] || fail "No original Theseus Metal shaders found; a substitute renderer is not supported."

SWIFT_OUT="$OUT/theseus"
BUNDLE="$APP/Theseus_Theseus.bundle"
mkdir -p "$SWIFT_OUT/metal" "$SWIFT_OUT/ModuleCache" "$BUNDLE" "$APP/Acknowledgements/Theseus"

# All vendor Swift, app Swift, and Bundle.module compile together. UIKit's ObjC
# entry point remains app/main.m, so Swift must never synthesize its own main.
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$TB_BUILD_ARCH-apple-ios15.0" \
  -swift-version 5 -parse-as-library -whole-module-optimization -O -emit-object \
  -module-name ThemeBoardGlass -module-cache-path "$SWIFT_OUT/ModuleCache" \
  "${SWIFT_SOURCES[@]}" -o "$SWIFT_OUT/ThemeBoardGlass.o"

# Keep original shaders intact; compile every .metal, even in nested folders.
# Numbered AIR outputs avoid collisions if upstream adds duplicate basenames.
AIR_OBJECTS=()
index=0
for source in "${METAL_SOURCES[@]}"; do
  air="$SWIFT_OUT/metal/$index.air"
  xcrun --sdk iphoneos metal -target air64-apple-ios15.0 -isysroot "$SDK" \
    -I "$VENDOR" -I "$(dirname "$source")" -c "$source" -o "$air"
  AIR_OBJECTS+=("$air")
  index=$((index + 1))
done
xcrun --sdk iphoneos metallib "${AIR_OBJECTS[@]}" -o "$BUNDLE/default.metallib"
[ -s "$SWIFT_OUT/ThemeBoardGlass.o" ] || fail "Theseus static Swift object is empty."
[ -s "$BUNDLE/default.metallib" ] || fail "Theseus default.metallib is empty."

# Bundle.module in Integration/TheseusBundle.swift resolves this exact bundle.
cat > "$BUNDLE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.ning.themeboard.theseus-resources</string>
<key>CFBundleName</key><string>Theseus_Theseus</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
PLIST
for notice in LICENSE NOTICE UPSTREAM.json Package.swift; do
  cp "$ROOT/Vendor/Theseus/$notice" "$APP/Acknowledgements/Theseus/$notice"
done
echo "== Theseus: ${#SWIFT_SOURCES[@]} Swift inputs / ${#METAL_SOURCES[@]} Metal inputs ($PIN)"
