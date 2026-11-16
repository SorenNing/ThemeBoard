#!/bin/bash
# macOS/Xcode: two native App+engine builds, four strictly verified debs.
# arm64 ordinary rootless => /var/jb; arm64e RootHide => unprefixed payload.
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail() { echo "error: $*" >&2; exit 1; }
[ "$(uname -s)" = "Darwin" ] || \
  fail "Original Theseus Swift/Metal requires macOS with full Xcode and the iPhoneOS SDK. Linux/iSH is unsupported; manually dispatch .github/workflows/build.yml."
command -v python3 >/dev/null 2>&1 || fail "python3 is required for vendor verification and deb packaging."
[ -f tools/verify_theseus.py ] || fail "Missing tools/verify_theseus.py; the pinned vendor manifest must be verified before building."
python3 tools/verify_theseus.py --root "$ROOT"
for tool in xcrun codesign plutil; do
  command -v "$tool" >/dev/null 2>&1 || fail "Missing $tool; install and select full Xcode."
done
for tool in clang swiftc swift-stdlib-tool metal metallib lipo; do
  xcrun --sdk iphoneos --find "$tool" >/dev/null || fail "Missing iPhoneOS tool: $tool"
done
[ -x /usr/libexec/PlistBuddy ] || fail "Missing macOS PlistBuddy."
[ -f tools/entitlements.plist ] || fail "Missing required App entitlements."
xcrun --sdk iphoneos metal --version >/dev/null 2>&1 || \
  fail "Metal compiler unavailable. On Xcode 26+, install MetalToolchain with xcodebuild -downloadComponent MetalToolchain before building."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
VER="$(awk '/^Version:/{print $2}' control)"
EV="$(awk '/^Version:/{print $2}' control.engine)"
[ "$VER" = "1.51" ] && [ "$EV" = "$VER" ] || fail "Both source controls must use Version: 1.51."
grep -q '@TB_PACKAGE_PREFIX@' postinst || fail "postinst must contain @TB_PACKAGE_PREFIX@."
# Deployment target is independent of the Debian package version/architecture.
VERY="15.0"
BUILD_NO="${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CI_OUT="$ROOT/build/ci"
shopt -s nullglob
APP_SOURCES=("$ROOT"/app/*.m)
ENGINE_SOURCES=("$ROOT"/engine/*.m)
[ "${#APP_SOURCES[@]}" -gt 0 ] || fail "No App Objective-C sources found."
[ "${#ENGINE_SOURCES[@]}" -gt 0 ] || fail "The engine is required in both architectures."
rm -rf "$CI_OUT"
mkdir -p "$CI_OUT" "$ROOT/dist"
# Never let an older or partial package set masquerade as this run's output.
rm -f "$ROOT"/dist/*.deb
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
echo "== SDK: $SDK"

for TB_BUILD_ARCH in arm64 arm64e; do
export TB_BUILD_ARCH
OUT="$CI_OUT/$TB_BUILD_ARCH"
APP="$OUT/ThemeBoard.app"
mkdir -p "$APP" "$OUT/objc"
echo "== Package: $VER; native $TB_BUILD_ARCH App + engine; iOS $VERY"

# Every ObjC translation unit, including main.m, is linked by the Swift driver.
OBJS=()
for f in "${APP_SOURCES[@]}"; do
  o="$OUT/objc/$(basename "$f" .m).o"
  xcrun --sdk iphoneos clang -c -fobjc-arc -O2 -isysroot "$SDK" \
    -target "$TB_BUILD_ARCH-apple-ios$VERY" -I"$ROOT/app" \
    -Wno-deprecated-declarations -o "$o" "$f"
  OBJS+=("$o")
done
SDK="$SDK" /bin/bash "$ROOT/tools/build-theseus.sh" "$OUT" "$APP"
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "$TB_BUILD_ARCH-apple-ios$VERY" -O \
  -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers \
  -framework Metal -framework MetalKit -framework IOSurface \
  -framework CoreVideo -framework Accelerate -lz \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker '@executable_path/Frameworks' \
  -o "$APP/ThemeBoard" "${OBJS[@]}" "$OUT/theseus/ThemeBoardGlass.o"
xcrun --sdk iphoneos lipo "$APP/ThemeBoard" -verify_arch "$TB_BUILD_ARCH"

# Finish all bundle contents before its final signature is made.
cp -R "$ROOT/app/Resources/." "$APP/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NO" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $VERY" "$APP/Info.plist"
plutil -lint "$APP/Info.plist" "$APP/Theseus_Theseus.bundle/Info.plist"
if [ -d "$ROOT/demo-themes" ]; then
  cp -R "$ROOT/demo-themes" "$APP/DemoThemes"
fi
file "$APP/ThemeBoard"

# Each App embeds the exact signed engine shipped in its same-arch engine deb.
mkdir -p "$OUT/engine"
EOBJS=()
for f in "${ENGINE_SOURCES[@]}"; do
  o="$OUT/engine/$(basename "$f" .m).o"
  xcrun --sdk iphoneos clang -c -fobjc-arc -O2 -isysroot "$SDK" \
    -target "$TB_BUILD_ARCH-apple-ios$VERY" -I"$ROOT/engine" \
    -Wno-deprecated-declarations -o "$o" "$f"
  EOBJS+=("$o")
done
xcrun --sdk iphoneos clang -target "$TB_BUILD_ARCH-apple-ios$VERY" -isysroot "$SDK" -dynamiclib \
  -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
  -framework Foundation -framework UIKit -framework CoreGraphics -framework ImageIO \
  -undefined dynamic_lookup -o "$OUT/engine/ThemeBoardEngine.dylib" "${EOBJS[@]}"
xcrun --sdk iphoneos lipo "$OUT/engine/ThemeBoardEngine.dylib" -verify_arch "$TB_BUILD_ARCH"
codesign --force --sign - "$OUT/engine/ThemeBoardEngine.dylib"
codesign --verify --deep --strict --verbose=2 "$OUT/engine/ThemeBoardEngine.dylib"
mkdir -p "$APP/Engine"
cp "$OUT/engine/ThemeBoardEngine.dylib" "$APP/Engine/"
cp "$ROOT/engine/ThemeBoardEngine.plist" "$APP/Engine/"
printf '%s\n' "$EV" > "$APP/Engine/version.txt"

# Scan the linked executable and nested code, copying only required runtime
# libraries (including transitive back-deployment dylibs) from selected Xcode.
# --resource-destination is for extra resource-library copies, not this runtime.
mkdir -p "$APP/Frameworks"
xcrun --sdk iphoneos swift-stdlib-tool --copy --verbose --platform iphoneos \
  --scan-executable "$APP/ThemeBoard" --scan-folder "$APP" \
  --destination "$APP/Frameworks"
SWIFT_DYLIB_COUNT=0
# A nullglob loop also handles zero copies under macOS Bash 3.2 with set -u.
for dylib in "$APP"/Frameworks/*.dylib; do
  xcrun --sdk iphoneos lipo "$dylib" -verify_arch "$TB_BUILD_ARCH"
  # Xcode can copy fat runtimes. Select the real matching slice, never relabel
  # an arm64 binary as arm64e. This invalidates its old signature: re-sign below.
  runtime_archs="$(xcrun --sdk iphoneos lipo -archs "$dylib")"
  if [ "$runtime_archs" != "$TB_BUILD_ARCH" ]; then
    xcrun --sdk iphoneos lipo "$dylib" -thin "$TB_BUILD_ARCH" -output "$OUT/runtime-thin.dylib"
    mv "$OUT/runtime-thin.dylib" "$dylib"
  fi
  codesign --force --sign - "$dylib"
  codesign --verify --strict --verbose=2 "$dylib"
  SWIFT_DYLIB_COUNT=$((SWIFT_DYLIB_COUNT + 1))
done
echo "== Swift back-deployment runtime: $SWIFT_DYLIB_COUNT copied dylibs (system Swift also uses /usr/lib/swift)"

# There is no entitlement-free fallback and no mutation inside APP after this.
# Engine, resources, metadata, icons and acknowledgements must already be final.
codesign --force --sign - --entitlements "$ROOT/tools/entitlements.plist" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements - "$APP" > "$OUT/signed-entitlements.plist"
python3 - "$ROOT/tools/entitlements.plist" "$OUT/signed-entitlements.plist" <<'PY'
import plistlib
import sys
with open(sys.argv[1], 'rb') as f:
    expected = plistlib.load(f)
with open(sys.argv[2], 'rb') as f:
    payload = f.read()
# Older codesign may prefix XML with its 8-byte entitlement-blob header.
if payload.startswith(bytes.fromhex('fade7171')):
    payload = payload[8:]
actual = plistlib.loads(payload)
if actual != expected:
    raise SystemExit('error: Signed App entitlements differ from tools/entitlements.plist')
print('== Signed App entitlements verified')
PY
for dylib in "$APP"/Frameworks/*.dylib; do
  codesign --verify --strict --verbose=2 "$dylib"
done
codesign --verify --deep --strict --verbose=2 "$APP/Engine/ThemeBoardEngine.dylib"

# Python-only ar/tar packaging preserves the final signed file bytes. The
# verifier reopens the FINAL debs and checks all headers, layouts and signatures.
python3 "$ROOT/tools/package.py" --root "$ROOT" --arch "$TB_BUILD_ARCH" --build-dir "$OUT"
done

python3 "$ROOT/tools/verify_packages.py" --root "$ROOT" \
  --report "$CI_OUT/verification.json"
ls -l "$ROOT"/dist/*.deb
shasum -a 256 "$ROOT"/dist/*.deb
