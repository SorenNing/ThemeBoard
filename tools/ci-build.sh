#!/bin/bash
# macOS/Xcode: complete arm64 iOS 15 App + original Theseus + optional arm64e engine.
# Keep the existing /var/jb package layout and the two existing package identities.
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
ARCH="$(awk '/^Architecture:/{print $2}' control)"
[ -n "$VER" ] && [ -n "$ARCH" ] || fail "control must specify Version and Architecture."
# Deployment target is independent of the Debian package version/architecture.
VERY="15.0"
BUILD_NO="${GITHUB_RUN_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT="$ROOT/build/ci"
APP="$OUT/ThemeBoard.app"
shopt -s nullglob
APP_SOURCES=("$ROOT"/app/*.m)
[ "${#APP_SOURCES[@]}" -gt 0 ] || fail "No App Objective-C sources found."
rm -rf "$OUT"
mkdir -p "$APP" "$OUT/objc"
echo "== SDK: $SDK"
echo "== Package: $VER / $ARCH; App: arm64 iOS $VERY"

# Every ObjC translation unit, including main.m, is linked by the Swift driver.
OBJS=()
for f in "${APP_SOURCES[@]}"; do
  o="$OUT/objc/$(basename "$f" .m).o"
  xcrun --sdk iphoneos clang -c -fobjc-arc -O2 -isysroot "$SDK" \
    -target "arm64-apple-ios$VERY" -I"$ROOT/app" \
    -Wno-deprecated-declarations -o "$o" "$f"
  OBJS+=("$o")
done
SDK="$SDK" /bin/bash "$ROOT/tools/build-theseus.sh" "$OUT" "$APP"
xcrun --sdk iphoneos swiftc -sdk "$SDK" -target "arm64-apple-ios$VERY" -O \
  -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework ImageIO -framework UniformTypeIdentifiers \
  -framework Metal -framework MetalKit -framework IOSurface \
  -framework CoreVideo -framework Accelerate -lz \
  -Xlinker -rpath -Xlinker /usr/lib/swift \
  -Xlinker -rpath -Xlinker '@executable_path/Frameworks' \
  -o "$APP/ThemeBoard" "${OBJS[@]}" "$OUT/theseus/ThemeBoardGlass.o"
xcrun --sdk iphoneos lipo -verify_arch arm64 "$APP/ThemeBoard"

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

# ---------- 引擎（arm64e）----------
ENGINE_BUILT=0
if compgen -G "engine/*.m" > /dev/null; then
  mkdir -p "$OUT/engine"
  EOBJS=()
  for f in engine/*.m; do
    o="$OUT/engine/$(basename "$f" .m).o"
    xcrun --sdk iphoneos clang -c -fobjc-arc -O2 -isysroot "$SDK" \
          -target "arm64e-apple-ios$VERY" -Iengine -Wno-deprecated-declarations -o "$o" "$f"
    EOBJS+=("$o")
  done
  xcrun --sdk iphoneos clang -target "arm64e-apple-ios$VERY" -isysroot "$SDK" -dynamiclib \
        -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
        -framework Foundation -framework UIKit -framework CoreGraphics -framework ImageIO \
        -undefined dynamic_lookup \
        -o "$OUT/engine/ThemeBoardEngine.dylib" "${EOBJS[@]}"
  xcrun --sdk iphoneos lipo -verify_arch arm64e "$OUT/engine/ThemeBoardEngine.dylib"
  codesign --force --sign - "$OUT/engine/ThemeBoardEngine.dylib"
  codesign --verify --strict --verbose=2 "$OUT/engine/ThemeBoardEngine.dylib"
  file "$OUT/engine/ThemeBoardEngine.dylib"
  # 同时放进 App 包，供 App 内「自装引擎」使用
  mkdir -p "$APP/Engine"
  cp "$OUT/engine/ThemeBoardEngine.dylib" "$APP/Engine/"
  cp engine/ThemeBoardEngine.plist "$APP/Engine/"
  awk '/^Version:/{print $2}' control.engine > "$APP/Engine/version.txt"
  codesign --verify --strict --verbose=2 "$APP/Engine/ThemeBoardEngine.dylib"
  ENGINE_BUILT=1
fi

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
  xcrun --sdk iphoneos lipo -verify_arch arm64 "$dylib"
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
if [ "$ENGINE_BUILT" = "1" ]; then
  codesign --verify --strict --verbose=2 "$APP/Engine/ThemeBoardEngine.dylib"
fi

# ---------- 打包（保留现有 /var/jb 布局）----------
STAGE="$OUT/stage"
mkdir -p "$STAGE/var/jb/Applications" "$STAGE/DEBIAN"
cp -R "$APP" "$STAGE/var/jb/Applications/"
codesign --verify --deep --strict --verbose=2 "$STAGE/var/jb/Applications/ThemeBoard.app"
if [ -d demo-themes ]; then
  mkdir -p "$STAGE/var/jb/Library/Themes"
  for theme in "$ROOT"/demo-themes/*.theme; do
    cp -R "$theme" "$STAGE/var/jb/Library/Themes/"
  done
fi
# 引擎单独打包，避免装 App 时触发 SpringBoard 重载
ESTAGE="$OUT/estage"
if [ "$ENGINE_BUILT" = "1" ]; then
  mkdir -p "$ESTAGE/var/jb/Library/MobileSubstrate/DynamicLibraries" "$ESTAGE/DEBIAN"
  cp "$OUT/engine/ThemeBoardEngine.dylib" "$ESTAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
  cp engine/ThemeBoardEngine.plist "$ESTAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
  codesign --verify --strict --verbose=2 "$ESTAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/ThemeBoardEngine.dylib"
  cp control.engine "$ESTAGE/DEBIAN/control"
  printf '#!/bin/sh\nexit 0\n' > "$ESTAGE/DEBIAN/postinst"
  chmod 755 "$ESTAGE/DEBIAN/postinst"
fi
cp control "$STAGE/DEBIAN/control"
cp postinst "$STAGE/DEBIAN/postinst"
cp postrm  "$STAGE/DEBIAN/postrm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

mkdir -p dist
DEB="dist/com.ning.themeboard_${VER}_${ARCH}.deb"
rm -f "$DEB"
( cd "$STAGE" && tar --no-mac-metadata -czf "$OUT/data.tar.gz" ./var )
( cd "$STAGE/DEBIAN" && tar --no-mac-metadata -czf "$OUT/control.tar.gz" ./control ./postinst ./postrm )
echo "2.0" > "$OUT/debian-binary"
python3 "$ROOT/tools/mkdeb.py" "$ROOT/$DEB" "$OUT"

if [ "$ENGINE_BUILT" = "1" ]; then
  EV=$(awk '/^Version:/{print $2}' control.engine)
  EDEB="dist/com.ning.themeboard.engine_${EV}_iphoneos-arm64e.deb"
  rm -f "$EDEB"
  EWORK="$OUT/edeb"; rm -rf "$EWORK"; mkdir -p "$EWORK"
  ( cd "$ESTAGE" && tar --no-mac-metadata -czf "$EWORK/data.tar.gz" ./var )
  ( cd "$ESTAGE/DEBIAN" && tar --no-mac-metadata -czf "$EWORK/control.tar.gz" ./control ./postinst )
  echo "2.0" > "$EWORK/debian-binary"
  python3 "$ROOT/tools/mkdeb.py" "$ROOT/$EDEB" "$EWORK"
  ls -l "$EDEB"
fi

ls -l "$DEB"
echo "== SHA256"; shasum -a 256 "$DEB" dist/*.deb
