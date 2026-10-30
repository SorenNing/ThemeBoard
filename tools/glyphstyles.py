#!/usr/bin/env python3
"""同一套形状，六种"字形画法"。底色统一纸白，只变字形风格。"""
import os, sys, math, importlib.util
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("r2", os.path.join(HERE, "redraw2.py"))
r2 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r2)

S = 240
W = 480
INK = (34, 30, 27)
CJK = "/usr/share/fonts/noto/NotoSansCJK-Bold.ttc"
OUT = "/var/minis/attachments"


def mask_of(key):
    lay = r2.glyph_layer(key, (255, 255, 255, 255))
    a = lay.split()[3]
    # 去掉内部镂空（齿轮/花瓣的洞要保留，这里只清理噪点）
    return a


def dilate(a, px):
    """在 480 空间膨胀 px 像素"""
    steps = max(1, int(round(px / 4)))
    for _ in range(steps):
        a = a.filter(ImageFilter.MaxFilter(9))
    return a


def tint_layer(a, color, alpha=1.0):
    lay = Image.new("RGBA", (W, W), tuple(color) + (0,))
    if alpha != 1.0:
        a = a.point(lambda v: int(v * alpha))
    lay.putalpha(a)
    return lay


def paper_base():
    rng = np.random.default_rng(5)
    noise = rng.normal(0, 3.6, (S, S, 1)).repeat(3, axis=2)
    arr = np.clip(np.array([247, 243, 235], np.float32) + noise, 0, 255)
    return Image.fromarray(arr.astype(np.uint8)).convert("RGBA")


def finish(layers):
    base = paper_base()
    for lay in layers:
        base = Image.alpha_composite(base, lay.resize((S, S), Image.LANCZOS))
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.2237), fill=255)
    base.putalpha(m)
    return base


# ---------- 六种字形画法 ----------
def gs_solid(key):
    a = mask_of(key)
    return finish([tint_layer(a, INK)])


def gs_line(key):
    """细线：只留 6px 轮廓"""
    a = mask_of(key)
    outer = dilate(a, 6)
    ring = np.clip(np.asarray(outer, np.int16) - np.asarray(a, np.int16), 0, 255)
    # 轮廓取"外扩后的边"更细：用外扩 - 原形后再取其中线，简化为直接外扩 3px
    ring_a = Image.fromarray(ring.astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.4))
    return finish([tint_layer(ring_a, INK)])


def gs_hollow(key):
    """粗空心：14px 描边，内部留白"""
    a = mask_of(key)
    outer = dilate(a, 14)
    ring = np.clip(np.asarray(outer, np.int16) - np.asarray(a, np.int16), 0, 255)
    ring_a = Image.fromarray(ring.astype(np.uint8)).filter(ImageFilter.MaxFilter(3))
    return finish([tint_layer(ring_a, INK)])


def gs_gradient(key):
    """渐变字：上下双色"""
    a = mask_of(key).resize((S, S), Image.LANCZOS)
    grad = Image.new("RGB", (S, S))
    d = ImageDraw.Draw(grad)
    c0, c1 = (18, 16, 15), (120, 104, 86)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)))
    lay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    lay.paste(grad, (0, 0), a)
    return finish([lay])


def gs_dots(key):
    """网点字：把形状变成圆点阵"""
    a = mask_of(key).resize((S, S), Image.LANCZOS)
    arr = np.asarray(a).astype(np.float32) / 255.0
    n = 18                      # 网格数
    cell = S / n
    small = np.asarray(a.resize((n, n), Image.LANCZOS)).astype(np.float32) / 255.0
    lay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    for r in range(n):
        for c in range(n):
            v = small[r, c]
            if v < 0.32:
                continue
            rad = cell * 0.5 * min(1.0, v * 1.25)
            cx, cy = (c + 0.5) * cell, (r + 0.5) * cell
            d.ellipse([cx - rad, cy - rad, cx + rad, cy + rad], fill=INK + (255,))
    return finish([lay])


def gs_3d(key):
    """立体：主体 + 右下投影 + 顶部高光"""
    a = mask_of(key)
    side = a.filter(ImageFilter.MaxFilter(3))
    off = Image.new("L", (W, W), 0)
    off.paste(side, (10, 12))
    shade = Image.composite(Image.new("L", (W, W), 255), Image.new("L", (W, W), 0),
                            Image.fromarray(np.clip(np.asarray(off, np.int16) - np.asarray(a, np.int16), 0, 255).astype(np.uint8)))
    dark = tint_layer(shade, (168, 150, 128))
    body = tint_layer(a, INK)
    return finish([dark, body])


STYLES = [("实心", gs_solid), ("细线", gs_line), ("粗空心", gs_hollow),
          ("渐变字", gs_gradient), ("网点", gs_dots), ("立体", gs_3d)]

SAMPLE = ["chat", "note", "cloud", "bag", "tv", "gear", "compass", "camera",
          "flower", "calc", "store", "phone", "mail", "pin", "clock"]
LABELS = r2.LABELS


def sheet(name, fn, keys, tag):
    cols, pad, head = 5, 14, 50
    rows = (len(keys) + cols - 1) // cols
    TW = 190
    Wd = pad + cols * (TW + pad)
    H = head + rows * (TW + pad + 20) + pad
    out = Image.new("RGB", (Wd, H), (250, 250, 252))
    d = ImageDraw.Draw(out)
    f = ImageFont.truetype(CJK, 25)
    sm = ImageFont.truetype(CJK, 15)
    d.text((pad, 11), name, font=f, fill=(26, 26, 30))
    for i, k in enumerate(keys):
        r, c = divmod(i, cols)
        im = fn(k).convert("RGBA").resize((TW, TW), Image.LANCZOS)
        x, y = pad + c * (TW + pad), head + r * (TW + pad + 20)
        out.paste(im, (x, y), im)
        d.text((x + 2, y + TW + 2), LABELS.get(k, k), font=sm, fill=(120, 120, 128))
    p = os.path.join(OUT, "g_%s.png" % tag)
    out.save(p)
    return p


if __name__ == "__main__":
    tags = ["solid", "line", "hollow", "gradient", "dots", "threeD"]
    for (name, fn), tag in zip(STYLES, tags):
        print(sheet(name, fn, SAMPLE[:10], tag))
