#!/bin/sh
# 本地打包：App + 本地编译的引擎 + 助手，全部在 iSH 内完成
set -e
ROOT=/var/minis/workspace/themeboard
SDK=/opt/iostool/sdks-master/iPhoneOS16.5.sdk
STAGE=/tmp/tb-pkg
OUT=$ROOT/dist
cd "$ROOT"

echo "== 1/4 编译 App"
sh tools/build-app.sh >/dev/null

echo "== 2/4 编译引擎（arm64e 重标记；放在 App 之后，避免被 build-app 清掉）"
sh tools/build-local-engine.sh >/dev/null
ENGINE=$ROOT/build/engine-local/ThemeBoardEngine.dylib
APP=$ROOT/build/ThemeBoard.app
mkdir -p "$APP/Engine"
cp "$ENGINE" engine/ThemeBoardEngine.plist "$APP/Engine/"
awk '/^Version:/{print $2}' control.engine > "$APP/Engine/version.txt"

echo "== 3/4 编译助手"
mkdir -p "$ROOT/build/helper"
clang-19 -c -O2 -isysroot "$SDK" -target arm64-apple-ios15.0 \
    -o "$ROOT/build/helper/helper.o" helper/themeboard_helper.c
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 \
    -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
    -o "$ROOT/build/helper/themeboard-helper" "$ROOT/build/helper/helper.o"
ldid -S "$ROOT/build/helper/themeboard-helper"

echo "== 4/4 打包"
mkdir -p "$OUT"
mkdeb() {
    NAME=$1; VER=$2; ARCH=$3; DIR=$4
    DEB="$OUT/${NAME}_${VER}_${ARCH}.deb"
    rm -f "$DEB"
    dpkg-deb --root-owner-group -Zgzip -b "$DIR" "$DEB" >/dev/null
    printf "   %-62s %8s bytes\n" "$(basename "$DEB")" "$(wc -c < "$DEB")"
}

V=$(awk '/^Version:/{print $2}' control)
EV=$(awk '/^Version:/{print $2}' control.engine)
HV=$(awk '/^Version:/{print $2}' control.helper)

rm -rf "$STAGE"; mkdir -p "$STAGE/var/jb/Applications" "$STAGE/DEBIAN"
cp -R "$APP" "$STAGE/var/jb/Applications/"
cp control "$STAGE/DEBIAN/control"; cp postinst postrm "$STAGE/DEBIAN/"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
mkdeb com.ning.themeboard "$V" iphoneos-arm64e "$STAGE"

rm -rf "$STAGE"; mkdir -p "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries" "$STAGE/DEBIAN"
cp "$ENGINE" engine/ThemeBoardEngine.plist "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp control.engine "$STAGE/DEBIAN/control"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/DEBIAN/postinst"; chmod 755 "$STAGE/DEBIAN/postinst"
mkdeb com.ning.themeboard.engine "$EV" iphoneos-arm64e "$STAGE"

rm -rf "$STAGE"; mkdir -p "$STAGE/var/jb/usr/bin" "$STAGE/DEBIAN"
cp "$ROOT/build/helper/themeboard-helper" "$STAGE/var/jb/usr/bin/"
chmod 4755 "$STAGE/var/jb/usr/bin/themeboard-helper"
cp control.helper "$STAGE/DEBIAN/control"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/DEBIAN/postinst"; chmod 755 "$STAGE/DEBIAN/postinst"
mkdeb com.ning.themeboard.helper "$HV" iphoneos-arm64 "$STAGE"

echo
cd "$OUT" && sha256sum *.deb
