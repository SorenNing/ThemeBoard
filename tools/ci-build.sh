#!/bin/bash
# 在 macOS runner 上构建：App（arm64）+ 引擎（arm64e，存在才编）+ 打包 deb
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
VER="$(awk '/^Version:/{print $2}' control)"
ARCH="$(awk '/^Architecture:/{print $2}' control)"
VERY="$(awk '/^Version:/{print $2}' control | cut -d. -f1).0"

OUT="$ROOT/build/ci"
APP="$OUT/ThemeBoard.app"
rm -rf "$OUT"; mkdir -p "$APP"

echo "== SDK: $SDK"
echo "== 版本: $VER / $ARCH"

# ---------- App（arm64）----------
OBJS=()
for f in app/*.m; do
  o="$OUT/$(basename "$f" .m).o"
  clang -c -fobjc-arc -O2 -isysroot "$SDK" -target "arm64-apple-ios$VERY" \
        -Iapp -Wno-deprecated-declarations -o "$o" "$f"
  OBJS+=("$o")
done

clang -target "arm64-apple-ios$VERY" -isysroot "$SDK" \
      -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
      -framework UIKit -framework Foundation -framework CoreGraphics \
      -framework QuartzCore -framework ImageIO -lz -framework UniformTypeIdentifiers \
      -o "$APP/ThemeBoard" "${OBJS[@]}"

codesign --force --sign - --entitlements tools/entitlements.plist "$APP" 2>/dev/null || \
    codesign --force --sign - "$APP"
cp app/Resources/Info.plist "$APP/Info.plist"
cp app/Resources/Icon*.png "$APP/" 2>/dev/null || true
rm -rf "$APP/DemoThemes"; cp -R demo-themes "$APP/DemoThemes" 2>/dev/null || true

file "$APP/ThemeBoard"

# ---------- 引擎（arm64e）----------
ENGINE_BUILT=0
if compgen -G "engine/*.m" > /dev/null; then
  mkdir -p "$OUT/engine"
  EOBJS=()
  for f in engine/*.m; do
    o="$OUT/engine/$(basename "$f" .m).o"
    clang -c -fobjc-arc -O2 -isysroot "$SDK" -target "arm64e-apple-ios$VERY" \
          -Iengine -Wno-deprecated-declarations -o "$o" "$f"
    EOBJS+=("$o")
  done
  clang -target "arm64e-apple-ios$VERY" -isysroot "$SDK" -dynamiclib \
        -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
        -framework Foundation -framework UIKit -framework CoreGraphics \
        -undefined dynamic_lookup \
        -o "$OUT/engine/ThemeBoardEngine.dylib" "${EOBJS[@]}"
  codesign --force --sign - "$OUT/engine/ThemeBoardEngine.dylib"
  file "$OUT/engine/ThemeBoardEngine.dylib"
  ENGINE_BUILT=1
fi

# ---------- 打包 ----------
STAGE="$OUT/stage"
mkdir -p "$STAGE/var/jb/Applications" "$STAGE/DEBIAN"
cp -R "$APP" "$STAGE/var/jb/Applications/"
if [ -d demo-themes ]; then
  mkdir -p "$STAGE/var/jb/Library/Themes"
  cp -R demo-themes/*.theme "$STAGE/var/jb/Library/Themes/" 2>/dev/null || true
fi
if [ "$ENGINE_BUILT" = "1" ]; then
  mkdir -p "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
  cp "$OUT/engine/ThemeBoardEngine.dylib" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
  cp engine/ThemeBoardEngine.plist "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/" 2>/dev/null || true
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
( cd "$OUT" && ar rc "$ROOT/$DEB" debian-binary control.tar.gz data.tar.gz )

ls -l "$DEB"
echo "== SHA256"; shasum -a 256 "$DEB"
