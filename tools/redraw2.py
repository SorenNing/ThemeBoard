#!/usr/bin/env python3
"""重绘图标 v2：一套字形 × 六种成品质感。

画布 480（2x）绘制后降采样，线宽/圆角统一，字形占格 56%。
六个风格：玻璃 / 渐变 / 细线 / 纸墨 / 浮雕 / 撞色
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUTDIR = "/var/minis/attachments"
SS = 2                    # 超采样
S = 240                   # 输出尺寸
W = S * SS
STROKE = 9 * SS           # 240 空间下 9
CJK = "/usr/share/fonts/noto/NotoSansCJK-Bold.ttc"
FONT_S = ImageFont.truetype(CJK, 17)


def sp(*v):
    return [x * SS for x in v]


# ---------- 字形（240 坐标空间，用 sp 缩放） ----------
def g_chat(d, c):
    d.rounded_rectangle(sp(56, 86, 146, 158), radius=26 * SS, fill=c)
    d.polygon(sp(76, 152, 68, 180, 100, 160), fill=c)
    d.rounded_rectangle(sp(108, 108, 186, 168), radius=20 * SS, fill=c)
    d.polygon(sp(164, 162, 172, 186, 144, 170), fill=c)
    for x in (82, 102, 122):
        d.ellipse(sp(x - 5, 116, x + 5, 126), fill=(0, 0, 0, 90))
    for x in (130, 152):
        d.ellipse(sp(x - 4.5, 132, x + 4.5, 141), fill=(0, 0, 0, 90))


def g_note(d, c):
    d.rounded_rectangle(sp(114, 62, 126, 150), radius=6 * SS, fill=c)
    d.ellipse(sp(84, 136, 128, 180), fill=c)
    d.polygon(sp(120, 62, 178, 80, 178, 104, 120, 88), fill=c)


def g_cloud(d, c):
    d.ellipse(sp(54, 54, 186, 186), outline=c, width=STROKE)
    d.rounded_rectangle(sp(112, 88, 121, 142), radius=4 * SS, fill=c)
    d.ellipse(sp(92, 132, 116, 156), fill=c)
    d.polygon(sp(116, 88, 148, 98, 148, 112, 116, 102), fill=c)


def g_bag(d, c):
    d.arc(sp(86, 50, 154, 122), start=180, end=360, fill=c, width=8 * SS)
    d.rounded_rectangle(sp(62, 94, 178, 188), radius=18 * SS, fill=c)


def g_tv(d, c):
    d.rounded_rectangle(sp(54, 88, 186, 172), radius=16 * SS, outline=c, width=STROKE)
    d.line(sp(80, 88, 108, 62), fill=c, width=STROKE - 1 * SS, joint="curve")
    d.line(sp(160, 88, 132, 62), fill=c, width=STROKE - 1 * SS, joint="curve")
    d.ellipse(sp(86, 122, 100, 136), fill=c)
    d.ellipse(sp(140, 122, 154, 136), fill=c)


def g_gear(d, c):
    for i in range(8):
        a = i * math.pi / 4
        cx, cy = 120 + math.cos(a) * 62, 120 + math.sin(a) * 62
        ux, uy = math.cos(a), math.sin(a)
        px, py = -uy, ux
        h, w = 13, 13
        pts = [(cx + ux * h + px * w, cy + uy * h + py * w),
               (cx + ux * h - px * w, cy + uy * h - py * w),
               (cx - ux * h - px * w, cy - uy * h - py * w),
               (cx - ux * h + px * w, cy - uy * h + py * w)]
        d.polygon([(x * SS, y * SS) for x, y in pts], fill=c)
    d.ellipse(sp(68, 68, 172, 172), outline=c, width=STROKE + 2 * SS)
    d.ellipse(sp(102, 102, 138, 138), fill=(0, 0, 0, 0))


def g_compass(d, c):
    d.ellipse(sp(52, 52, 188, 188), outline=c, width=STROKE)
    d.polygon(sp(120, 72, 138, 126, 120, 114, 102, 126), fill=c)
    d.polygon(sp(120, 168, 138, 114, 120, 126, 102, 114), fill=c)


def g_camera(d, c):
    d.rounded_rectangle(sp(52, 90, 188, 176), radius=20 * SS, outline=c, width=STROKE)
    d.rounded_rectangle(sp(98, 70, 142, 92), radius=8 * SS, fill=c)
    d.ellipse(sp(90, 106, 150, 166), outline=c, width=STROKE)


def g_flower(d, c):
    for i in range(8):
        a = i * math.pi / 4
        x, y = 120 + math.cos(a) * 47, 120 + math.sin(a) * 47
        d.ellipse(sp(x - 23, y - 23, x + 23, y + 23), fill=c)
    d.ellipse(sp(100, 100, 140, 140), fill=(0, 0, 0, 0))


def g_calc(d, c):
    d.rounded_rectangle(sp(74, 52, 166, 188), radius=14 * SS, outline=c, width=STROKE)
    d.rounded_rectangle(sp(88, 66, 152, 92), radius=5 * SS, fill=c)
    for r in range(3):
        for col in range(3):
            x, y = 96 + col * 24, 114 + r * 24
            d.ellipse(sp(x - 6, y - 6, x + 6, y + 6), fill=c)


def g_store(d, c):
    d.line(sp(70, 172, 112, 90), fill=c, width=13 * SS, joint="curve")
    d.line(sp(170, 172, 128, 90), fill=c, width=13 * SS, joint="curve")
    d.line(sp(94, 140, 146, 140), fill=c, width=10 * SS, joint="curve")


def g_phone(d, c):
    d.rounded_rectangle(sp(80, 42, 160, 198), radius=22 * SS, outline=c, width=STROKE + 1 * SS)
    d.line(sp(110, 64, 130, 64), fill=c, width=6 * SS)
    d.line(sp(104, 178, 136, 178), fill=c, width=6 * SS)


def g_mail(d, c):
    d.rounded_rectangle(sp(58, 80, 182, 164), radius=16 * SS, outline=c, width=STROKE)
    d.line(sp(66, 92, 120, 130, 174, 92), fill=c, width=STROKE, joint="curve")


def g_pin(d, c):
    d.ellipse(sp(76, 52, 164, 140), outline=c, width=STROKE)
    d.ellipse(sp(104, 80, 136, 112), fill=c)
    d.polygon(sp(94, 130, 146, 130, 120, 190), fill=c)


def g_clock(d, c):
    d.ellipse(sp(52, 52, 188, 188), outline=c, width=STROKE)
    d.line(sp(120, 76, 120, 122, 148, 138), fill=c, width=8 * SS, joint="curve")


GLYPHS = {"chat": g_chat, "note": g_note, "cloud": g_cloud, "bag": g_bag, "tv": g_tv,
          "gear": g_gear, "compass": g_compass, "camera": g_camera, "flower": g_flower,
          "calc": g_calc, "store": g_store, "phone": g_phone, "mail": g_mail,
          "pin": g_pin, "clock": g_clock}

BRAND = {
    "chat": (76, 217, 100), "note": (240, 240, 245), "cloud": (255, 82, 82),
    "bag": (255, 130, 48), "tv": (86, 168, 255), "gear": (176, 180, 190),
    "compass": (74, 158, 255), "camera": (232, 232, 238), "flower": (255, 108, 190),
    "calc": (255, 208, 84), "store": (96, 162, 255), "phone": (104, 224, 126),
    "mail": (108, 172, 255), "pin": (104, 216, 148), "clock": (238, 238, 244),
}


def glyph_layer(key, color, blur=0):
    lay = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    GLYPHS[key](d, color)
    if blur:
        lay = lay.filter(ImageFilter.GaussianBlur(blur))
    return lay


def tile_bg(top, bot):
    img = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(img)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return img


def mask_round(img, radius_ratio=0.2237):
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1],
                                        radius=int(img.size[0] * radius_ratio), fill=255)
    out = img.convert("RGBA")
    out.putalpha(m)
    return out


def shade(c, f):
    return tuple(max(0, min(255, int(v * f))) for v in c)


# ---------- 六种成品质感 ----------
def _shadow(base, g, alpha=60, dy=3, blur=2.2):
    sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sh.paste((0, 0, 0, alpha), (0, dy), g.split()[3])
    base = Image.alpha_composite(base, sh.filter(ImageFilter.GaussianBlur(blur)))
    return Image.alpha_composite(base, g)


def usable(c, thresh=205):
    """太浅的品牌色在浅底上换成深灰，避免看不见"""
    return (42, 42, 48) if (c[0] * 299 + c[1] * 587 + c[2] * 114) / 1000 > thresh else c


def st_white(key):
    """纯白：白底 + 品牌色字形"""
    c = usable(BRAND[key])
    base = tile_bg((255, 255, 255), (246, 247, 250)).convert("RGBA")
    g = glyph_layer(key, shade(c, 0.92) + (255,)).resize((S, S), Image.LANCZOS)
    return mask_round(_shadow(base, g, 42, 3, 2.4))


def st_paper(key):
    """纸白：暖白纸纹 + 墨黑字形"""
    rng = np.random.default_rng(11)
    noise = rng.normal(0, 4.2, (S, S, 1)).repeat(3, axis=2)
    paper = np.clip(np.array([246, 242, 233], np.float32) + noise, 0, 255)
    base = Image.fromarray(paper.astype(np.uint8)).convert("RGBA")
    g = glyph_layer(key, (38, 34, 30, 255)).resize((S, S), Image.LANCZOS)
    return mask_round(_shadow(base, g, 34, 2, 1.6))


def st_cream(key):
    """奶油：奶油底 + 深棕字形"""
    base = tile_bg((253, 247, 234), (247, 236, 214)).convert("RGBA")
    g = glyph_layer(key, (74, 56, 40, 255)).resize((S, S), Image.LANCZOS)
    return mask_round(_shadow(base, g, 40, 2, 2.0))


def st_tint(key):
    """浅品牌：品牌色打淡成底 + 深品牌字形"""
    c = BRAND[key]
    top = tuple(min(255, int(v * 0.16 + 244)) for v in c)
    bot = tuple(min(255, int(v * 0.30 + 226)) for v in c)
    base = tile_bg(top, bot).convert("RGBA")
    g = glyph_layer(key, shade(c, 0.52) + (255,)).resize((S, S), Image.LANCZOS)
    return mask_round(_shadow(base, g, 46, 3, 2.2))


def st_emboss_light(key):
    """浅浮雕：浅灰底 + 同色压凸"""
    c = BRAND[key]
    base = tile_bg((236, 237, 241), (216, 218, 226)).convert("RGBA")
    g = glyph_layer(key, (255, 255, 255, 255))
    a = g.split()[3]
    hi = np.asarray(a, np.int16)
    up = np.roll(hi, -3 * SS, axis=0)
    dn = np.roll(hi, 3 * SS, axis=0)
    light = Image.fromarray(np.clip(up - hi, 0, 255).astype(np.uint8)).resize((S, S), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.7))
    dark = Image.fromarray(np.clip(dn - hi, 0, 255).astype(np.uint8)).resize((S, S), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.7))
    body = a.resize((S, S), Image.LANCZOS)
    l1 = Image.new("RGBA", (S, S), (255, 255, 255, 0)); l1.putalpha(light.point(lambda v: int(v * 0.85)))
    l2 = Image.new("RGBA", (S, S), (96, 100, 112, 0)); l2.putalpha(dark.point(lambda v: int(v * 0.75)))
    l3 = Image.new("RGBA", (S, S), shade(c, 0.62) + (0,)); l3.putalpha(body.point(lambda v: int(v * 0.78)))
    base = Image.alpha_composite(base, l2)
    base = Image.alpha_composite(base, l3)
    base = Image.alpha_composite(base, l1)
    return mask_round(base)


def st_mono(key):
    """单色灰：浅灰底 + 近黑字形"""
    base = tile_bg((244, 244, 246), (232, 232, 236)).convert("RGBA")
    g = glyph_layer(key, (28, 28, 31, 255)).resize((S, S), Image.LANCZOS)
    return mask_round(_shadow(base, g, 26, 2, 1.6))


STYLES = [("纯白", st_white), ("纸白", st_paper), ("奶油", st_cream),
          ("浅品牌", st_tint), ("浅浮雕", st_emboss_light), ("单色灰", st_mono)]

SAMPLE = ["chat", "note", "cloud", "bag", "tv", "gear", "compass", "camera",
          "flower", "calc", "store", "phone", "mail", "pin", "clock"]
LABELS = {"chat": "微信", "note": "抖音", "cloud": "网易云", "bag": "淘宝", "tv": "B站",
          "gear": "设置", "compass": "Safari", "camera": "相机", "flower": "相册",
          "calc": "计算器", "store": "App Store", "phone": "电话", "mail": "邮件",
          "pin": "地图", "clock": "时钟"}


def sheet(name, fn, keys):
    cols, pad, head = 5, 14, 52
    rows = (len(keys) + cols - 1) // cols
    TW = 200
    Wd = pad + cols * (TW + pad)
    H = head + rows * (TW + pad + 22) + pad
    out = Image.new("RGB", (Wd, H), (250, 250, 252))
    d = ImageDraw.Draw(out)
    f = ImageFont.truetype(CJK, 26)
    d.text((pad, 12), name, font=f, fill=(24, 24, 28))
    for i, k in enumerate(keys):
        r, c = divmod(i, cols)
        im = fn(k).convert("RGBA").resize((TW, TW), Image.LANCZOS)
        x, y = pad + c * (TW + pad), head + r * (TW + pad + 22)
        out.paste(im, (x, y), im)
        d.text((x + 2, y + TW + 3), LABELS.get(k, k), font=FONT_S, fill=(120, 120, 128))
    p = os.path.join(OUTDIR, "l_%s.png" % {"纯白": "white", "纸白": "paper", "奶油": "cream",
                                           "浅品牌": "tint", "浅浮雕": "embosslight",
                                           "单色灰": "mono"}[name])
    out.save(p)
    return p


if __name__ == "__main__":
    for name, fn in STYLES:
        print(sheet(name, fn, SAMPLE[:10]))
