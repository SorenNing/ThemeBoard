#!/bin/sh
# 本地编译引擎 dylib：arm64e 目标 + 传统 bind 表 + 事后改 cpusubtype
set -e
ROOT=/var/minis/workspace/themeboard
SDK=/opt/iostool/sdks-master/iPhoneOS16.5.sdk
OUT=$ROOT/build/engine-local
rm -rf "$OUT"; mkdir -p "$OUT"

cd "$ROOT"
for f in engine/*.m; do
  clang-19 -c -fobjc-arc -O2 -isysroot "$SDK" -target arm64e-apple-ios15.0 \
      -Iengine -Wno-deprecated-declarations \
      -o "$OUT/$(basename "$f" .m).o" "$f"
done

ld64.lld -dylib -arch arm64e \
    -platform_version ios 15.0 16.5 \
    -undefined dynamic_lookup \
    -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
    -framework Foundation -framework UIKit -framework CoreGraphics -framework ImageIO \
    -o "$OUT/ThemeBoardEngine.dylib" "$OUT"/*.o

python3 - "$OUT/ThemeBoardEngine.dylib" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, 'rb').read())
magic = struct.unpack('<I', d[:4])[0]
assert magic == 0xfeedfacf, hex(magic)
cpu, sub = struct.unpack('<ii', d[4:12])
struct.pack_into('<I', d, 8, 0x80000002)
open(p, 'wb').write(d)
nc = struct.unpack('<I', d[16:20])[0]
off, cmds = 32, []
for _ in range(nc):
    c, sz = struct.unpack('<II', d[off:off+8])
    cmds.append(c); off += sz
print("cpusubtype:", hex(sub), "-> 0x80000002")
print("chained_fixups:", 0x80000034 in cmds, "| dyld_info:", 0x22 in cmds)
PY

ldid -S "$OUT/ThemeBoardEngine.dylib"
file "$OUT/ThemeBoardEngine.dylib"
echo "== $OUT/ThemeBoardEngine.dylib"
