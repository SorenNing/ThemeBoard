#!/usr/bin/env python3
"""生成 ThemeBoard 的 App 图标（渐变底 + 3x3 圆角方块网格，右下角一块高亮）"""
from PIL import Image, ImageDraw, ImageFilter
import math

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# 背景渐变（对角）
top = (94, 92, 230)      # indigo
bot = (175, 82, 222)     # purple
for y in range(S):
    t = y / (S - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    d.line([(0, y), (S, y)], fill=(r, g, b, 255))

# 柔和光斑
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([S * 0.55, -S * 0.15, S * 1.25, S * 0.55], fill=(255, 255, 255, 60))
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.08))
img = Image.alpha_composite(img, glow)

d = ImageDraw.Draw(img)

# 3x3 网格
cell, gap, margin = 190, 40, 152
total = cell * 3 + gap * 2
ox = (S - total) // 2
oy = (S - total) // 2
radius = 46

for row in range(3):
    for col in range(3):
        x = ox + col * (cell + gap)
        y = oy + row * (cell + gap)
        if row == 2 and col == 2:
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=radius,
                                fill=(255, 255, 255, 245))
            d.rounded_rectangle([x + 46, y + 46, x + cell - 46, y + cell - 46], radius=22,
                                fill=(94, 92, 230, 255))
        else:
            d.rounded_rectangle([x, y, x + cell, y + cell], radius=radius,
                                fill=(255, 255, 255, 58),
                                outline=(255, 255, 255, 120), width=3)

# 圆角遮罩（iOS 图标会再裁一次，这里先裁出方圆形）
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.2237), fill=255)
img.putalpha(mask)

out = "/var/minis/workspace/themeboard/app/Resources"
for name, size in [("Icon60@2x.png", 120), ("Icon60@3x.png", 180), ("Icon60.png", 60)]:
    img.resize((size, size), Image.LANCZOS).save(f"{out}/{name}")
    print("wrote", name, size)
img.resize((512, 512), Image.LANCZOS).save(f"{out}/Icon-large.png")
print("done")
