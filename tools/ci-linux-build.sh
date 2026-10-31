#!/bin/bash
# Linux(ubuntu) 上用 sbingner 的 arm64e 工具链编译引擎，产出可安装的 deb
set -e
ROOT=$(pwd)
THEOS=${THEOS:-$HOME/theos}
OUT="$ROOT/out"

echo "===== 1. 准备 Theos 与工具链 ====="
mkdir -p "$THEOS/toolchain/linux" "$THEOS/sdks" "$OUT"
if [ ! -f "$THEOS/toolchain/linux/.ok" ]; then
  URL=https://github.com/sbingner/llvm-project/releases/download/v10.0.0-2/linux-ios-arm64e-clang-toolchain.tar.lzma
  curl -L -m 900 -o /tmp/tc.tar.lzma "$URL"
  ls -l /tmp/tc.tar.lzma
  echo "== 解压 =="
  cd "$THEOS/toolchain/linux"
  if ! tar -xJf /tmp/tc.tar.lzma 2>/tmp/tar.err; then
    echo "tar -xJf 失败，尝试 xz 管道："
    cat /tmp/tar.err | head -5
    xz -dc /tmp/tc.tar.lzma | tar -x 2>/tmp/tar2.err || cat /tmp/tar2.err | head -5
  fi
  echo "== 解压后目录（前 30 项）=="
  find "$THEOS/toolchain/linux" -maxdepth 4 | head -30
  cd "$ROOT"
  touch "$THEOS/toolchain/linux/.ok"
fi

# 注意：这些是符号链接，不能用 -type f
TCBIN=$(find "$THEOS/toolchain" -maxdepth 4 -name 'bin' -type d 2>/dev/null | head -1)
# 只在 bin 目录里找（find 会先命中 include/clang 这个目录）
CLANG_FOUND=""
LD_FOUND=""
if [ -d "$TCBIN" ]; then
  for c in "$TCBIN/clang" "$TCBIN/clang++"; do
    [ -x "$c" ] && CLANG_FOUND="$c" && break
  done
  for c in "$TCBIN/ld64" "$TCBIN/ld64.lld" "$TCBIN/ld"; do
    [ -x "$c" ] && LD_FOUND="$c" && break
  done
fi
echo "TCBIN: $TCBIN"
ls -l "$TCBIN" 2>/dev/null | head -20
echo "clang: $CLANG_FOUND"
echo "ld   : $LD_FOUND"

echo "===== 2. SDK ====="
if ! ls -d "$THEOS/sdks/"*.sdk >/dev/null 2>&1; then
  curl -L -m 900 -o /tmp/sdk.tar.gz "https://github.com/theos/sdks/archive/refs/heads/master.tar.gz"
  tar -xzf /tmp/sdk.tar.gz -C "$THEOS/sdks" --strip-components=1
fi
SDK=$(ls -d "$THEOS/sdks/iPhoneOS16.5.sdk" 2>/dev/null || ls -d "$THEOS/sdks/"*.sdk | head -1)
echo "SDK: $SDK"

echo "===== 3. ldid ====="
if ! command -v ldid >/dev/null 2>&1; then
  curl -L -m 300 -o /tmp/ldid "https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/ldid_linux_x86_64"
  chmod +x /tmp/ldid
  mkdir -p "$HOME/.local/bin"
  cp /tmp/ldid "$HOME/.local/bin/ldid"
  export PATH="$HOME/.local/bin:$PATH"
fi
ldid -h >/dev/null 2>&1 && echo "ldid ok" || echo "ldid 不可用（签名会跳过）"

echo "===== 4. 编译引擎 ====="
mkdir -p "$OUT/obj"
for f in engine/*.m; do
  "$CLANG_FOUND" -c -fobjc-arc -O2 -isysroot "$SDK" -target arm64e-apple-ios15.0 \
    -Iengine -Wno-deprecated-declarations -o "$OUT/obj/$(basename "$f" .m).o" "$f"
done

"$LD_FOUND" -dylib -arch arm64e -platform_version ios 15.0 16.5 \
    -syslibroot "$SDK" -undefined dynamic_lookup \
    -o "$OUT/ThemeBoardEngine.dylib" "$OUT/obj"/*.o

echo "===== 5. 检查产物 ====="
python3 - <<'PY'
import struct
try:
    d = open('out/ThemeBoardEngine.dylib','rb').read()
    cpu, sub = struct.unpack('<ii', d[4:12])
    nc = struct.unpack('<I', d[16:20])[0]
    off, cmds = 32, []
    for _ in range(nc):
        c, sz = struct.unpack('<II', d[off:off+8]); cmds.append(c); off += sz
    print("size", len(d), "cpu", hex(cpu & 0xffffffff), "sub", hex(sub & 0xffffffff))
    print("chained:", 0x80000034 in cmds, "dyld_info_only:", 0x80000022 in cmds)
    print("ARM64E_OK" if (sub & 0xffffffff) == 0x80000002 else "NOT_ARM64E")
except Exception as e:
    print("检查失败", e)
PY

ldid -S "$OUT/ThemeBoardEngine.dylib" 2>/dev/null || echo "签名跳过"

echo "===== 6. 打包 deb ====="
V=$(awk '/^Version:/{print $2}' control.engine)
STAGE=/tmp/eng-stage
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
cp "$OUT/ThemeBoardEngine.dylib" engine/ThemeBoardEngine.plist \
   "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/"
cp control.engine "$STAGE/DEBIAN/control"
printf '#!/bin/sh\nexit 0\n' > "$STAGE/DEBIAN/postinst"
chmod 755 "$STAGE/DEBIAN/postinst"
find "$STAGE/var" -type d -exec chmod 755 {} \;
find "$STAGE/var" -type f -exec chmod 644 {} \;
chmod 755 "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/ThemeBoardEngine.dylib"
mkdir -p "$ROOT/dist"
dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$ROOT/dist/com.ning.themeboard.engine_${V}_iphoneos-arm64e.deb"
ls -l "$ROOT/dist/"
echo "===== 完成 ====="
