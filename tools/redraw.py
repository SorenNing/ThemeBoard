#!/usr/bin/env python3
"""几何重绘：不用原图，逐个 app 用基本图形重新画字形。

一套统一语言：等线宽、圆头端点、几何构成、纯色块面。
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = "/var/minis/attachments/redraw_sheet.png"
S = 240
STROKE = 11
CJK = "/usr/share/fonts/noto/NotoSansCJK-Bold.ttc"


def rr(d, box, r, **kw):
    d.rounded_rectangle(box, radius=r, **kw)


def line(d, pts, w=STROKE, c=(255, 255, 255), cap="round"):
    d.line(pts, fill=c, width=w, joint="curve")


def circle(d, cx, cy, r, w=STROKE, c=(255, 255, 255)):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=c, width=w)


# ---------------- 字形库 ----------------
def g_chat(d, c):
    """双气泡（微信）"""
    rr(d, [46, 76, 152, 156], 30, fill=c)
    d.polygon([(70, 150), (62, 180), (98, 158)], fill=c)
    rr(d, [106, 102, 196, 168], 24, fill=c)
    d.polygon([(172, 162), (180, 188), (148, 170)], fill=c)
    for x in (80, 102, 124):
        d.ellipse([x - 6, 110, x + 6, 122], fill=(30, 32, 36))
    for x in (132, 152):
        d.ellipse([x - 5, 128, x + 5, 138], fill=(30, 32, 36))


def g_note(d, c):
    """音符（抖音）"""
    line(d, [(122, 62), (122, 150)], STROKE + 4, c)
    d.ellipse([86, 140, 130, 184], fill=c)
    d.polygon([(122, 62), (176, 78), (176, 104), (122, 90)], fill=c)


def g_cloud_music(d, c):
    """圆形 + 音符（网易云）"""
    circle(d, 120, 120, 66, STROKE, c)
    line(d, [(112, 92), (112, 142)], 9, c)
    d.ellipse([90, 134, 114, 158], fill=c)
    d.polygon([(112, 92), (146, 102), (146, 118), (112, 108)], fill=c)


def g_bag(d, c):
    """购物袋（淘宝）"""
    d.arc([84, 48, 156, 124], start=180, end=360, fill=c, width=14)
    rr(d, [60, 96, 180, 190], 22, fill=c)
    line(d, [(60, 96), (180, 96)], 0, c)


def g_tv(d, c):
    """电视机（B 站）"""
    rr(d, [52, 84, 188, 172], 20, fill=c)
    line(d, [(78, 84), (104, 58)], 10, c)
    line(d, [(162, 84), (136, 58)], 10, c)
    for x in (96, 144):
        d.ellipse([x - 7, 120, x + 7, 134], fill=(30, 32, 36))


def g_gear(d, c):
    """齿轮（设置）"""
    for i in range(8):
        a = i * math.pi / 4
        cx, cy = 120 + math.cos(a) * 60, 120 + math.sin(a) * 60
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        w, h = 15, 17
        pts = [
            (cx + ux * h + px * w, cy + uy * h + py * w),
            (cx + ux * h - px * w, cy + uy * h - py * w),
            (cx - ux * h - px * w, cy - uy * h - py * w),
            (cx - ux * h + px * w, cy - uy * h + py * w),
        ]
        d.polygon(pts, fill=c)
    circle(d, 120, 120, 56, STROKE + 3, c)
    circle(d, 120, 120, 19, STROKE + 1, (0, 0, 0, 0))


def g_compass(d, c):
    """罗盘（Safari）"""
    circle(d, 120, 120, 68, STROKE, c)
    d.polygon([(120, 76), (136, 128), (120, 116), (104, 128)], fill=c)
    d.polygon([(120, 164), (136, 112), (120, 124), (104, 112)], fill=c)


def g_camera(d, c):
    """相机"""
    rr(d, [48, 88, 192, 178], 24, fill=c)
    rr(d, [96, 68, 144, 92], 10, fill=c)
    d.ellipse([88, 104, 152, 168], fill=(30, 32, 36))
    d.ellipse([98, 114, 142, 158], fill=c)


def g_flower(d, c):
    """花瓣（相册）"""
    for i in range(8):
        a = i * math.pi / 4
        x, y = 120 + math.cos(a) * 42, 120 + math.sin(a) * 42
        d.ellipse([x - 30, y - 30, x + 30, y + 30], fill=c)
    d.ellipse([100, 100, 140, 140], fill=(30, 32, 36))


def g_calc(d, c):
    """算盘格（计算器）"""
    rr(d, [70, 52, 170, 188], 16, fill=c)
    rr(d, [84, 66, 156, 96], 6, fill=(30, 32, 36))
    for row in range(3):
        for col in range(3):
            x = 92 + col * 30
            y = 116 + row * 26
            d.ellipse([x - 8, y - 8, x + 8, y + 8], fill=(30, 32, 36))


def g_appstore(d, c):
    """字母 A（App Store）"""
    line(d, [(70, 172), (112, 92)], 16, c)
    line(d, [(170, 172), (128, 92)], 16, c)
    line(d, [(94, 140), (146, 140)], 13, c)
    line(d, [(62, 194), (178, 194)], 11, c)


def g_phone(d, c):
    """手机轮廓（电话）"""
    rr(d, [74, 40, 166, 200], 26, outline=c, width=STROKE + 2)
    line(d, [(108, 66), (132, 66)], 8, c)
    line(d, [(100, 176), (140, 176)], 8, c)


def g_mail(d, c):
    """信封"""
    rr(d, [56, 78, 184, 166], 18, fill=c)
    d.polygon([(66, 92), (120, 130), (174, 92)], fill=(30, 32, 36))
    d.polygon([(56, 78), (184, 78), (120, 148)], fill=(30, 32, 36)) if False else None


def g_pin(d, c):
    """定位（地图）"""
    d.ellipse([78, 52, 162, 136], outline=c, width=STROKE)
    d.ellipse([104, 78, 136, 110], fill=c)
    d.polygon([(96, 126), (144, 126), (120, 188)], fill=c)


def g_clock(d, c):
    circle(d, 120, 120, 68, STROKE, c)
    line(d, [(120, 76), (120, 120), (148, 136)], 10, c)


def g_bili(d, c):
    pass


def g_zhi(d, c):
    """支付宝的「支」"""
    f = ImageFont.truetype(CJK, 150)
    d.text((120, 118), "支", font=f, fill=c, anchor="mm")


GLYPHS = {
    "chat": g_chat, "note": g_note, "cloudmusic": g_cloud_music, "bag": g_bag,
    "tv": g_tv, "gear": g_gear, "compass": g_compass, "camera": g_camera,
    "flower": g_flower, "calc": g_calc, "appstore": g_appstore, "phone": g_phone,
    "mail": g_mail, "pin": g_pin, "clock": g_clock, "zhi": g_zhi,
}

# ---------------- 配色 ----------------
PALETTES = {
    "chat":       ((28, 34, 30), (76, 217, 100)),
    "note":       ((18, 18, 20), (255, 255, 255)),
    "cloudmusic": ((34, 20, 22), (255, 92, 92)),
    "bag":        ((36, 24, 14), (255, 138, 40)),
    "tv":         ((20, 26, 38), (96, 178, 255)),
    "gear":       ((30, 30, 32), (198, 200, 208)),
    "compass":    ((16, 26, 44), (90, 168, 255)),
    "camera":     ((26, 26, 28), (235, 235, 240)),
    "flower":     ((34, 22, 34), (255, 122, 196)),
    "calc":       ((20, 22, 26), (255, 214, 92)),
    "appstore":   ((14, 24, 42), (110, 170, 255)),
    "phone":      ((16, 32, 22), (110, 230, 130)),
    "mail":       ((16, 24, 38), (120, 180, 255)),
    "pin":        ((18, 30, 24), (120, 220, 150)),
    "clock":      ((22, 22, 24), (240, 240, 245)),
    "zhi":        ((14, 30, 52), (120, 180, 255)),
}

BILLBOARD = [
    ("微信", "chat"), ("抖音", "note"), ("网易云", "cloudmusic"), ("淘宝", "bag"),
    ("B 站", "tv"), ("设置", "gear"), ("Safari", "compass"), ("相机", "camera"),
    ("相册", "flower"), ("计算器", "calc"), ("App Store", "appstore"), ("电话", "phone"),
    ("邮件", "mail"), ("地图", "pin"), ("时钟", "clock"), ("支付宝", "zhi"),
]


def render(key, size=S):
    bg, fg = PALETTES[key]
    # 背景：极轻的垂直渐变，避免死板
    top = tuple(min(255, int(v * 1.25) + 6) for v in bg)
    img = Image.new("RGB", (size, size))
    d0 = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d0.line([(0, y), (size, y)], fill=tuple(int(top[i] + (bg[i] - top[i]) * t) for i in range(3)))

    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d._image = layer
    GLYPHS[key](d, fg + (255,))
    # 柔和投影
    sh = layer.filter(ImageFilter.GaussianBlur(6))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (0, 4), sh.split()[3])
    img = Image.alpha_composite(img.convert("RGBA"), shadow)
    img = Image.alpha_composite(img, layer)

    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.2237), fill=255)
    img.putalpha(m)
    return img


def sheet():
    cols, pad, head = 4, 16, 60
    rows = (len(BILLBOARD) + cols - 1) // cols
    W = pad + cols * (S + pad)
    H = head + rows * (S + pad + 26) + pad
    out = Image.new("RGB", (W, H), (14, 14, 15))
    d = ImageDraw.Draw(out)
    f = ImageFont.truetype(CJK, 26)
    fs = ImageFont.truetype(CJK, 18)
    d.text((pad, 14), "重绘样张 · 几何字形", font=f, fill=(240, 240, 244))
    for i, (name, key) in enumerate(BILLBOARD):
        r, c = divmod(i, cols)
        x = pad + c * (S + pad)
        y = head + r * (S + pad + 26)
        out.paste(render(key).convert("RGB"), (x, y), render(key))
        d.text((x + 2, y + S + 4), name, font=fs, fill=(170, 170, 178))
    out.save(OUT)
    print("sheet:", OUT, out.size)


if __name__ == "__main__":
    sheet()
