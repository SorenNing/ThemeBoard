#!/usr/bin/env python3
"""生成两套演示主题（Aurora / Noir），SnowBoard/Anemone 兼容的 IconBundles 结构。

输出：/var/minis/workspace/themeboard/demo-themes/<Name>.theme/IconBundles/<bid>@3x.png
"""
import os, math
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = "/var/minis/workspace/themeboard/demo-themes"
S = 180
RADIUS = int(S * 0.2237)
FONT = ImageFont.truetype("/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", 74)

APPS = [
    ("com.apple.mobilesafari",     "Safari",   (0.55, 0.72, 1.00), (0.10, 0.42, 0.95), "compass"),
    ("com.apple.mobilemail",       "邮件",      (0.45, 0.78, 1.00), (0.05, 0.38, 0.90), "mail"),
    ("com.apple.MobileSMS",        "信息",      (0.45, 1.00, 0.55), (0.10, 0.75, 0.25), "bubble"),
    ("com.apple.mobilephone",      "电话",      (0.50, 1.00, 0.50), (0.05, 0.70, 0.30), "phone"),
    ("com.apple.Maps",             "地图",      (0.65, 1.00, 0.70), (0.10, 0.65, 0.45), "pin"),
    ("com.apple.mobilecal",        "日历",      (1.00, 1.00, 1.00), (0.95, 0.95, 0.97), "cal"),
    ("com.apple.mobileslideshow",  "照片",      (1.00, 0.95, 0.55), (1.00, 0.45, 0.65), "flower"),
    ("com.apple.camera",           "相机",      (0.55, 0.58, 0.62), (0.20, 0.22, 0.26), "camera"),
    ("com.apple.Preferences",      "设置",      (0.62, 0.64, 0.70), (0.30, 0.32, 0.38), "gear"),
    ("com.apple.Music",            "音乐",      (1.00, 0.55, 0.75), (0.90, 0.15, 0.45), "note"),
    ("com.apple.mobiletimer",      "时钟",      (0.35, 0.36, 0.40), (0.10, 0.10, 0.14), "clock"),
    ("com.apple.AppStore",         "App Store", (0.45, 0.80, 1.00), (0.10, 0.50, 0.95), "store"),
]


def gradient(size, c0, c1):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)],
               fill=tuple(int((c0[i] + (c1[i] - c0[i]) * t) * 255) for i in range(3)))
    return img


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def draw_glyph(d, kind, c=(255, 255, 255), w=9):
    """在 180x180 画布中心画一个简易图标"""
    cx = cy = S // 2
    if kind == "compass":
        d.ellipse([cx-52, cy-52, cx+52, cy+52], outline=c, width=7)
        d.polygon([(cx, cy-34), (cx+13, cy+6), (cx, cy-6), (cx-13, cy+6)], fill=c)
        d.polygon([(cx, cy+34), (cx+10, cy+10), (cx-10, cy+10)], fill=(255, 255, 255, 150))
    elif kind == "mail":
        d.rounded_rectangle([cx-54, cy-36, cx+54, cy+36], radius=12, outline=c, width=7)
        d.line([(cx-50, cy-30), (cx, cy+6), (cx+50, cy-30)], fill=c, width=7)
    elif kind == "bubble":
        d.rounded_rectangle([cx-54, cy-42, cx+54, cy+30], radius=24, outline=c, width=7)
        d.polygon([(cx-16, cy+30), (cx-6, cy+52), (cx+10, cy+30)], fill=c)
    elif kind == "phone":
        d.arc([cx-58, cy-58, cx+22, cy+22], start=190, end=280, fill=c, width=11)
        d.arc([cx-22, cy-22, cx+58, cy+58], start=100, end=190, fill=c, width=11)
        d.ellipse([cx-64, cy-20, cx-38, cy+6], fill=c)
        d.ellipse([cx+38, cy-6, cx+64, cy+20], fill=c)
    elif kind == "pin":
        d.ellipse([cx-34, cy-54, cx+34, cy+14], outline=c, width=8)
        d.ellipse([cx-13, cy-33, cx+13, cy-7], fill=c)
        d.polygon([(cx-24, cy+6), (cx+24, cy+6), (cx, cy+56)], fill=c)
    elif kind == "cal":
        d.rounded_rectangle([cx-52, cy-52, cx+52, cy+52], radius=14, fill=(255, 255, 255, 235))
        d.rounded_rectangle([cx-52, cy-52, cx+52, cy-24], radius=14, fill=(255, 90, 80))
        d.text((cx, cy + 12), "30", font=FONT, fill=(60, 60, 60), anchor="mm")
    elif kind == "flower":
        for i in range(8):
            a = i * math.pi / 4
            x = cx + int(30 * math.cos(a)); y = cy + int(30 * math.sin(a))
            d.ellipse([x-20, y-20, x+20, y+20], fill=c)
        d.ellipse([cx-16, cy-16, cx+16, cy+16], fill=(255, 255, 255, 90))
    elif kind == "camera":
        d.rounded_rectangle([cx-54, cy-32, cx+54, cy+42], radius=16, outline=c, width=7)
        d.rounded_rectangle([cx-22, cy-44, cx+22, cy-26], radius=8, outline=c, width=7)
        d.ellipse([cx-22, cy-12, cx+22, cy+32], outline=c, width=7)
    elif kind == "gear":
        for i in range(8):
            a = i * math.pi / 4
            x = cx + int(math.cos(a) * 48); y = cy + int(math.sin(a) * 48)
            d.ellipse([x-11, y-11, x+11, y+11], fill=c)
        d.ellipse([cx-36, cy-36, cx+36, cy+36], outline=c, width=9)
        d.ellipse([cx-14, cy-14, cx+14, cy+14], outline=c, width=9)
    elif kind == "note":
        d.ellipse([cx-46, cy+12, cx-8, cy+42], fill=c)
        d.ellipse([cx+8, cy+2, cx+46, cy+32], fill=c)
        d.rectangle([cx-14, cy-48, cx-6, cy+30], fill=c)
        d.rectangle([cx+40, cy-56, cx+48, cy+22], fill=c)
        d.polygon([(cx-14, cy-48), (cx+48, cy-56), (cx+48, cy-40), (cx-14, cy-32)], fill=c)
    elif kind == "clock":
        d.ellipse([cx-52, cy-52, cx+52, cy+52], outline=c, width=8)
        d.line([(cx, cy), (cx, cy-34)], fill=c, width=8)
        d.line([(cx, cy), (cx+24, cy+12)], fill=c, width=8)
    elif kind == "store":
        for i, y in enumerate([cy-30, cy, cy+30]):
            d.line([(cx-38 + i*4, y), (cx+38 - i*4, y)], fill=c, width=9)


def make_theme(name, dark, accent_shift):
    out = os.path.join(ROOT, name + ".theme", "IconBundles")
    os.makedirs(out, exist_ok=True)
    for bid, label, c0, c1, glyph in APPS:
        if dark:
            base = gradient(S, (0.09, 0.09, 0.11), (0.03, 0.03, 0.04))
            gold = (0.83, 0.69, 0.42)
            glyph_color = tuple(int(v * 255) for v in gold)
        else:
            base = gradient(S, c0, c1)
            glyph_color = (255, 255, 255)
        base = base.convert("RGBA")
        d = ImageDraw.Draw(base)
        if dark:
            # 细金线边框
            d.rounded_rectangle([2, 2, S - 3, S - 3], radius=RADIUS, outline=(212, 175, 105, 180), width=2)
        draw_glyph(d, glyph, glyph_color)
        base.putalpha(rounded_mask(S, RADIUS))
        base.save(os.path.join(out, bid + "@3x.png"))
        base.resize((120, 120), Image.LANCZOS).save(os.path.join(out, bid + "@2x.png"))
    print("theme:", name, len(APPS), "apps")


os.makedirs(ROOT, exist_ok=True)
make_theme("Aurora", dark=False, accent_shift=0)
make_theme("Noir", dark=True, accent_shift=1)
