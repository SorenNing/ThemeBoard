#!/bin/sh
# 打包 ThemeBoard 为 roothide/rootless 可安装的 deb
# 注意：/var/minis 是 fake FS，chmod 不生效，所以暂存目录必须放 /tmp
set -e
ROOT=/var/minis/workspace/themeboard
VER=$(awk "/^Version:/{print \$2}" "$ROOT/control")
OUT=$ROOT/dist
STAGE=/tmp/tb-stage

rm -rf "$STAGE"; mkdir -p "$STAGE/var/jb/Applications" "$STAGE/DEBIAN"
cp -R "$ROOT/build/ThemeBoard.app" "$STAGE/var/jb/Applications/"
mkdir -p "$STAGE/var/jb/Library/Themes"
cp -R "$ROOT"/demo-themes/*.theme "$STAGE/var/jb/Library/Themes/"
cp "$ROOT/control" "$STAGE/DEBIAN/control"
cp "$ROOT/postinst" "$STAGE/DEBIAN/postinst"
cp "$ROOT/postrm"  "$STAGE/DEBIAN/postrm"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
chmod 644 "$STAGE/DEBIAN/control"
find "$STAGE/var" -type d -exec chmod 755 {} +
find "$STAGE/var" -type f -exec chmod 644 {} +
chmod 755 "$STAGE/var/jb/Applications/ThemeBoard.app/ThemeBoard"

mkdir -p "$OUT"
ARCH=$(awk '/^Architecture:/{print $2}' "$ROOT/control")
DEB=$OUT/com.ning.themeboard_${VER}_${ARCH}.deb
rm -f "$DEB"
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$DEB"

echo "== $DEB"
ls -l "$DEB"
dpkg-deb -f "$DEB" Package Version Architecture
echo "-- 内容 --"
dpkg-deb -c "$DEB" | sed -n '1,10p'
sha256sum "$DEB"
