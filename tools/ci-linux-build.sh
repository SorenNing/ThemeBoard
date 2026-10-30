#!/bin/bash
# 在 ubuntu runner 上用 Theos 的 Linux 工具链尝试编出 arm64e 引擎
set -x
THEOS=${THEOS:-$HOME/theos}
SDK=""
TC=""

echo "===== 1. 准备 Theos ====="
if [ ! -d "$THEOS/.git" ]; then
  git clone --recursive https://github.com/theos/theos.git "$THEOS" || true
fi
git clone --depth 1 https://github.com/theos/sdks.git "$THEOS/sdks" 2>/dev/null || true
ls "$THEOS" | head -20

echo "===== 2. 获取 Linux iOS 工具链 ====="
if [ ! -d "$THEOS/toolchain/linux/iphone/bin" ]; then
  # 官方安装脚本（非交互）
  if [ -x "$THEOS/bin/install-theos" ]; then
    yes | "$THEOS/bin/install-theos" || true
  fi
fi
if [ ! -d "$THEOS/toolchain/linux/iphone/bin" ]; then
  echo "install-theos 未产出工具链，改用 sbingner/llvm-project 的 Linux 工具链"
  curl -sS -m 60 "https://api.github.com/repos/sbingner/llvm-project/releases" -o /tmp/rel.json || true
  python3 - <<'PY' > /tmp/tcurl.txt
import json
try:
    d = json.load(open('/tmp/rel.json'))
    for r in d:
        for a in r.get('assets', []):
            if a['name'].endswith('.tar.lzma'):
                print(a['browser_download_url'])
                raise SystemExit
except Exception as e:
    print('')
PY
  URL=$(head -1 /tmp/tcurl.txt)
  echo "toolchain url: $URL"
  if [ -n "$URL" ]; then
    curl -L -m 600 -o /tmp/tc.tar.lzma "$URL"
    mkdir -p "$THEOS/toolchain/linux"
    tar -x --lzma -f /tmp/tc.tar.lzma -C "$THEOS/toolchain/linux" || tar -xJf /tmp/tc.tar.lzma -C "$THEOS/toolchain/linux" || true
  fi
fi
ls "$THEOS/toolchain" 2>/dev/null || echo "无 toolchain 目录"
ls "$THEOS/toolchain/linux/iphone/bin" 2>/dev/null | head -20 || true

echo "===== 3. 选 SDK ====="
for c in "$THEOS/sdks/iPhoneOS16.5.sdk" "$THEOS/sdks/iPhoneOS15.6.sdk"; do
  [ -d "$c" ] && SDK="$c"
done
[ -z "$SDK" ] && SDK=$(ls -d "$THEOS/sdks/"*.sdk 2>/dev/null | head -1)
echo "SDK=$SDK"

echo "===== 4. 选编译器 ====="
for c in "$THEOS/toolchain/linux/iphone/bin/clang" "$THEOS/toolchain/linux/iphone/bin/clang++"; do
  [ -x "$c" ] && TC="$c" && break
done
echo "clang=$TC"
[ -n "$TC" ] && "$TC" --version | head -3

echo "===== 5. 编译 ====="
mkdir -p out
if [ -n "$TC" ] && [ -n "$SDK" ]; then
  for f in engine/*.m; do
    "$TC" -c -fobjc-arc -O2 -isysroot "$SDK" -target arm64e-apple-ios15.0 \
      -Iengine -Wno-deprecated-declarations -o "out/$(basename "$f" .m).o" "$f" || exit 1
  done

  LD=""
  for c in "$THEOS/toolchain/linux/iphone/bin/ld64" "$THEOS/toolchain/linux/iphone/bin/ld" "$THEOS/toolchain/linux/iphone/bin/ld64.lld"; do
    [ -x "$c" ] && LD="$c" && break
  done
  echo "ld=$LD"
  "$LD" -dylib -arch arm64e -platform_version ios 15.0 16.5 \
      -syslibroot "$SDK" -undefined dynamic_lookup \
      -o out/ThemeBoardEngine.dylib out/*.o || exit 1

  file out/ThemeBoardEngine.dylib || true
  python3 - <<'PY' || true
import struct
d = open('out/ThemeBoardEngine.dylib','rb').read()
cpu, sub = struct.unpack('<ii', d[4:12])
print("size", len(d), "cpu", hex(cpu & 0xffffffff), "sub", hex(sub & 0xffffffff))
nc = struct.unpack('<I', d[16:20])[0]
off, cmds = 32, []
for _ in range(nc):
    c, sz = struct.unpack('<II', d[off:off+8]); cmds.append(c); off += sz
print("chained:", 0x80000034 in cmds, "dyld_info_only:", 0x80000022 in cmds, "codesig:", 0x1d in cmds)
PY
fi
echo "===== 完成 ====="