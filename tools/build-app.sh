#!/bin/sh
# 本地构建 ThemeBoard.app（arm64，可装可跑；引擎 dylib 必须走 Actions）
set -e
ROOT=/var/minis/workspace/themeboard
SDK=/opt/iostool/sdks-master/iPhoneOS16.5.sdk
OUT=$ROOT/build
APP=$OUT/ThemeBoard.app
CC=clang-19
LD=ld64.lld
MIN=15.0

rm -rf "$OUT"; mkdir -p "$APP"

SRCS=$(ls "$ROOT"/app/*.m)
OBJS=""
for f in $SRCS; do
  o="$OUT/$(basename "$f" .m).o"
  # 增量：.o 比所有头文件和自身都新就跳过
  if [ -f "$o" ] && [ "$o" -nt "$f" ] && [ -z "$(find "$ROOT/app" -name '*.h' -newer "$o" | head -1)" ]; then
      OBJS="$OBJS $o"; continue
  fi
  $CC -c -fobjc-arc -O2 -isysroot "$SDK" -target arm64-apple-ios$MIN \
      -I"$ROOT/app" -I"$SDK/System/Library/Frameworks/UIKit.framework/Headers" \
      -Wno-deprecated-declarations -o "$o" "$f"
  OBJS="$OBJS $o"
done

$LD -arch arm64 -platform_version ios $MIN 16.5 -o "$APP/ThemeBoard" \
    -undefined dynamic_lookup \
    -F"$SDK/System/Library/Frameworks" -L"$SDK/usr/lib" \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework QuartzCore -framework ImageIO -lz -framework UniformTypeIdentifiers \
    $OBJS

ldid -S"$ROOT/tools/entitlements.plist" "$APP/ThemeBoard"
cp "$ROOT"/app/Resources/Info.plist "$APP/Info.plist"
cp "$ROOT"/app/Resources/Icon*.png "$APP/" 2>/dev/null || true
rm -rf "$APP/DemoThemes"; cp -R "$ROOT/demo-themes" "$APP/DemoThemes" 2>/dev/null || cp -R demo-themes "$APP/DemoThemes" 2>/dev/null || true
chmod -R 755 "$APP"
echo "== built: $APP"
ls -la "$APP"
