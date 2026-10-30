#!/usr/bin/env python3
"""6 套非金色候选风格，同一批图标，拼成对比方格。"""
import os, glob, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SRC = "/tmp/icons/iOS26图标_泽哥二编/IconBundles"
OUT = "/var/minis/attachments/noir_variants.png"
WORK, SIZE = 512, 150

BG_TOP, BG_BOT = (26, 26, 28), (8, 8, 9)


def bg_gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    return img


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def inner_mask(size, inset):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([inset, inset, size - 1 - inset, size - 1 - inset],
                                        radius=int(size * 0.2237) - inset, fill=255)
    return m


def prep(path):
    im = Image.open(path).convert("RGBA").resize((WORK, WORK), Image.LANCZOS)
    arr = np.asarray(im).astype(np.float32)
    rgb, alpha = arr[..., :3], arr[..., 3] / 255.0

    w = WORK
    ring = np.concatenate([arr[4, 8:w-8, :3].reshape(-1, 3), arr[w-5, 8:w-8, :3].reshape(-1, 3),
                           arr[8:w-8, 4, :3].reshape(-1, 3), arr[8:w-8, w-5, :3].reshape(-1, 3)])
    bg = np.median(ring, axis=0) if ring.size else np.array([255., 255., 255.])

    lum = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    bg_luma = float(bg @ np.array([0.299, 0.587, 0.114], np.float32))
    if bg_luma > 215:
        lum = 255.0 - lum
    gray = lum.copy()
    lo, hi = np.percentile(lum, 2), np.percentile(lum, 98)
    if hi - lo < 1:
        hi = lo + 1
    lum = np.clip((lum - lo) / (hi - lo) * 255, 0, 255)

    li = Image.fromarray(lum.astype(np.uint8)).filter(ImageFilter.GaussianBlur(1.2))
    gx = np.asarray(li.filter(ImageFilter.FIND_EDGES)).astype(np.float32)
    k = np.asarray(li.filter(ImageFilter.Kernel((3, 3), [-1, -1, -1, -1, 8, -1, -1, -1, -1], 1, 0))).astype(np.float32)
    mag = np.maximum(gx, k)
    p = max(1.0, np.percentile(mag, 99.4))
    line = np.clip(mag / p * 255, 0, 255)
    key = Image.fromarray((line > 62).astype(np.uint8) * 255)
    key = key.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
    line = np.asarray(key).astype(np.float32) / 255.0
    line *= np.asarray(inner_mask(WORK, int(WORK * 0.035))).astype(np.float32) / 255.0

    return dict(lum=lum, gray=gray, line=line, alpha=alpha, rgb=rgb, bg=bg)


def finish(core_rgb, alpha_arr, rim=(255, 255, 255, 190)):
    base = bg_gradient(SIZE).convert("RGBA")
    a = Image.fromarray((np.clip(alpha_arr, 0, 1) * 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS)
    c = Image.fromarray(np.clip(core_rgb, 0, 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS)
    base.paste(c, (0, 0), a)
    d = ImageDraw.Draw(base)
    r = int(SIZE * 0.2237)
    d.rounded_rectangle([1, 1, SIZE - 2, SIZE - 2], radius=r, outline=rim, width=2)
    g = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse([-SIZE*.3, -SIZE*.55, SIZE*1.3, SIZE*.42], fill=(255, 255, 255, 8))
    g = g.filter(ImageFilter.GaussianBlur(SIZE * 0.05))
    base = Image.alpha_composite(base, g)
    base.putalpha(rounded_mask(SIZE, r))
    return base


def tint(level, hi, mid, lo):
    level = np.clip(level, 0, 1)[..., None]
    lower = lo + (mid - lo) * (level / 0.55)
    upper = mid + (hi - mid) * ((level - 0.55) / 0.45)
    return np.where(level < 0.55, lower, upper)


WHITE = (np.array([255, 255, 255], np.float32), np.array([228, 228, 232], np.float32), np.array([170, 172, 178], np.float32))
SILVER = (np.array([240, 245, 250], np.float32), np.array([176, 189, 205], np.float32), np.array([110, 124, 140], np.float32))
ICE = (np.array([255, 255, 255], np.float32), np.array([168, 208, 255], np.float32), np.array([70, 120, 190], np.float32))


def v_white_line(d):
    core = tint(0.55 + d["line"] * 0.45, *WHITE)
    return finish(core, d["line"] * d["alpha"])


def v_silver_line(d):
    core = tint(0.5 + d["line"] * 0.5, *SILVER)
    return finish(core, d["line"] * d["alpha"], rim=(210, 220, 235, 190))


def v_ice_line(d):
    core = tint(0.45 + d["line"] * 0.55, *ICE)
    return finish(core, d["line"] * d["alpha"], rim=(150, 190, 245, 200))


def v_line_fill(d):
    mass = np.clip((d["lum"] - 120) / 135.0, 0, 1) * 0.16
    s = np.clip(d["line"] + mass, 0, 1)
    core = tint(0.5 + s * 0.5, *WHITE)
    return finish(core, s * d["alpha"])


def v_solid(d):
    dist = np.abs(d["rgb"] - d["bg"][None, None, :]).max(axis=2)
    body = np.clip((dist - 26) / 90.0, 0, 1)
    m = Image.fromarray((body * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    body = np.asarray(m).astype(np.float32) / 255
    core = tint(0.66 + body * 0.34, *WHITE)
    return finish(core, body * d["alpha"])


def v_mono(d):
    """灰度明暗：保留原图层次（不反相）"""
    g = d["gray"]
    core = np.repeat((g * 0.86 + 14)[..., None], 3, axis=2)
    return finish(core, d["alpha"], rim=(200, 200, 205, 180))


def v_original(d):
    """保留原色，只换深底 + 白边"""
    return finish(d["rgb"], d["alpha"])


VARIANTS = [
    ("A 白线", v_white_line),
    ("B 银线", v_silver_line),
    ("C 冰蓝线", v_ice_line),
    ("D 白线+淡块面", v_line_fill),
    ("E 白色实心", v_solid),
    ("F 灰度明暗", v_mono),
    ("G 原色+深底", v_original),
]


def sample_paths(n=8):
    fs = sorted(glob.glob(os.path.join(SRC, "*.png")))
    want = ["com.tencent.xin", "com.ss.iphone.ugc.Aweme", "com.netease.cloudmusic",
            "com.taobao.taobao4iphone", "com.apple.Preferences", "com.apple.mobilesafari",
            "tv.danmaku.bilianime", "com.eg.android.AlipayGphone"]
    out = []
    for w in want:
        for f in fs:
            if os.path.basename(f) in (w + ".png", w + "@3x.png"):
                out.append(f); break
    while len(out) < n:
        f = fs[len(out) * 37 % len(fs)]
        if f not in out:
            out.append(f)
    return out[:n]


def sheet():
    paths = sample_paths(8)
    pad, label = 12, 26
    cols, rows = len(paths), len(VARIANTS)
    W = pad + cols * (SIZE + pad)
    H = (rows + 1) * (SIZE + pad + label) + label
    out = Image.new("RGB", (W, H), (16, 16, 17))
    d = ImageDraw.Draw(out)
    from PIL import ImageFont
    f = ImageFont.truetype("/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", 17)

    d.text((pad, 2), "原始", font=f, fill=(160, 160, 165))
    for i, p in enumerate(paths):
        orig = Image.open(p).convert("RGBA").resize((SIZE, SIZE), Image.LANCZOS)
        out.paste(orig, (pad + i * (SIZE + pad), label), orig)

    prepared = [prep(p) for p in paths]
    for r, (name, fn) in enumerate(VARIANTS):
        yy = (r + 1) * (SIZE + pad + label) + label
        d.text((pad, yy - 21), name, font=f, fill=(235, 235, 240))
        for c, dd in enumerate(prepared):
            out.paste(fn(dd).convert("RGB"), (pad + c * (SIZE + pad), yy))
    out.save(OUT)
    print("sheet:", OUT, out.size)


if __name__ == "__main__":
    sheet()
