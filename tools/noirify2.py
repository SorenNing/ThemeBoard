#!/usr/bin/env python3
"""Noir 金 风格转换 v2：高清边缘 + 自适应阈值 + 淡金填充。

只做一件事：把任意彩色图标变成「深底 + 金线 + 淡金块面」，与参考图一致。
"""
import os, glob, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops

SRC = "/tmp/icons/iOS26图标_泽哥二编/IconBundles"
OUT_BASE = "/var/minis/workspace/themeboard/noir-themes"

PALETTES = {
    "white":  (np.array([255, 255, 255], np.float32), np.array([236, 236, 240], np.float32), np.array([150, 152, 158], np.float32)),
    "silver": (np.array([238, 242, 246], np.float32), np.array([190, 199, 210], np.float32), np.array([120, 130, 145], np.float32)),
    "gold":   (np.array([248, 224, 170], np.float32), np.array([196, 156, 88], np.float32), np.array([120, 90, 44], np.float32)),
}
PALETTE = "white"
GOLD_HI, GOLD_MID, GOLD_LO = PALETTES[PALETTE]
BG_TOP = (24, 22, 19)
BG_BOT = (8, 8, 8)
RIM = (255, 255, 255)

WORK = 512          # 处理分辨率
OUT = 180           # 输出 @3x


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
    """去掉图标自带的圆角边框（外圈 inset 像素置 0）"""
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [inset, inset, size - 1 - inset, size - 1 - inset],
        radius=int(size * 0.2237) - inset, fill=255)
    return m


def dominant_bg(im):
    w, h = im.size
    a = np.asarray(im)
    ring = np.concatenate([
        a[4, 8:w - 8, :3].reshape(-1, 3),
        a[h - 5, 8:w - 8, :3].reshape(-1, 3),
        a[8:h - 8, 4, :3].reshape(-1, 3),
        a[8:h - 8, w - 5, :3].reshape(-1, 3),
    ])
    if ring.size == 0:
        return np.array([255, 255, 255], dtype=np.float32)
    # 中位色
    return np.median(ring, axis=0).astype(np.float32)


def otsu(vals, bins=256):
    hist, _ = np.histogram(vals, bins=bins, range=(0, 256))
    hist = hist.astype(np.float64)
    total = hist.sum()
    if total == 0:
        return 128
    prob = hist / total
    omega = np.cumsum(prob)
    mu = np.cumsum(prob * np.arange(bins))
    mu_t = mu[-1]
    denom = omega * (1 - omega)
    denom[denom == 0] = 1e-9
    sigma = (mu_t * omega - mu) ** 2 / denom
    return int(np.argmax(sigma))


def gold_color(level):
    """level 0..1 → 金色"""
    level = np.clip(level, 0, 1)[..., None]
    lo = GOLD_LO[None, None, :]
    mid = GOLD_MID[None, None, :]
    hi = GOLD_HI[None, None, :]
    lower = lo + (mid - lo) * (level / 0.55)
    upper = mid + (hi - mid) * ((level - 0.55) / 0.45)
    return np.where(level < 0.55, lower, upper)


def render(path_in, size_out=OUT, work=WORK):
    im = Image.open(path_in).convert("RGBA").resize((work, work), Image.LANCZOS)
    arr = np.asarray(im).astype(np.float32)
    rgb = arr[..., :3]
    alpha = arr[..., 3] / 255.0

    bg = dominant_bg(im)
    lum = rgb @ np.array([0.299, 0.587, 0.114], dtype=np.float32)
    if bg.mean() > 150:            # 浅色底 → 反相，保证底暗字亮
        lum = 255.0 - lum

    # 归一化 + 局部对比
    lo_p, hi_p = np.percentile(lum, 2), np.percentile(lum, 98)
    if hi_p - lo_p < 1:
        hi_p = lo_p + 1
    lum = np.clip((lum - lo_p) / (hi_p - lo_p) * 255.0, 0, 255)

    lum_img = Image.fromarray(lum.astype(np.uint8))
    lum_img = lum_img.filter(ImageFilter.GaussianBlur(1.2))

    # 梯度
    gx = np.asarray(lum_img.filter(ImageFilter.FIND_EDGES)).astype(np.float32)
    edges = np.asarray(lum_img.filter(ImageFilter.Kernel((3, 3), [-1,-1,-1,-1,8,-1,-1,-1,-1], scale=1, offset=0))
                       ).astype(np.float32)
    mag = np.maximum(gx, edges)
    p = np.percentile(mag, 99.4)
    if p < 1:
        p = 1
    mag = np.clip(mag / p * 255.0, 0, 255)

    thr = 62.0
    line = (mag > thr).astype(np.float32)

    # 去掉自带外框
    inner = np.asarray(inner_mask(work, int(work * 0.035))).astype(np.float32) / 255.0
    line *= inner

    # 加粗一点，再缩回输出尺寸得到平滑线
    line_img = Image.fromarray((np.clip(line, 0, 1) * 255).astype(np.uint8))
    line_img = line_img.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.8))
    line = np.asarray(line_img).astype(np.float32) / 255.0

    # 块面：亮部（原图标的主体）给 20% 金
    mass = np.clip((lum - 118) / 137.0, 0, 1) * 0.10
    mass *= inner

    strength = np.clip(line * 1.0 + mass, 0, 1)
    gold = gold_color(0.55 + strength * 0.45)
    core = Image.fromarray(gold.astype(np.uint8))

    a = (strength * alpha).astype(np.float32)
    a_img = Image.fromarray((a * 255).astype(np.uint8)).resize((size_out, size_out), Image.LANCZOS)

    base = bg_gradient(size_out).convert("RGBA")
    core_small = core.resize((size_out, size_out), Image.LANCZOS)
    base.paste(core_small, (0, 0), a_img)

    d = ImageDraw.Draw(base)
    r = int(size_out * 0.2237)
    d.rounded_rectangle([1, 1, size_out - 2, size_out - 2], radius=r, outline=RIM + (205,), width=2)

    gloss = Image.new("RGBA", (size_out, size_out), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse([-size_out * 0.3, -size_out * 0.55, size_out * 1.3, size_out * 0.42],
               fill=(255, 255, 255, 10))
    gloss = gloss.filter(ImageFilter.GaussianBlur(size_out * 0.05))
    base = Image.alpha_composite(base, gloss)
    base.putalpha(rounded_mask(size_out, r))
    return base


def sample_paths(n=8):
    fs = sorted(glob.glob(os.path.join(SRC, "*.png")))
    want = ["com.apple.mobilesafari", "com.apple.MobileSMS", "com.apple.Preferences",
            "com.tencent.xin", "com.taobao.taobao4iphone", "com.ss.iphone.ugc.Aweme",
            "com.netease.cloudmusic", "tv.danmaku.bilianime"]
    picked = []
    for w in want:
        for f in fs:
            if os.path.basename(f) in (w + ".png", w + "@3x.png"):
                picked.append(f); break
    return picked[:n]


def sheet(paths=None):
    paths = paths or sample_paths()
    size, pad, label = OUT, 14, 24
    cols = len(paths)
    W = pad + cols * (size + pad)
    H = label * 2 + pad * 3 + size * 2
    out = Image.new("RGB", (W, H), (18, 17, 16))
    d = ImageDraw.Draw(out)
    from PIL import ImageFont
    f = ImageFont.truetype("/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", 18)
    d.text((pad, 2), "original / noir", font=f, fill=(150, 150, 150))
    y0 = label + pad
    for i, p in enumerate(paths):
        x = pad + i * (size + pad)
        orig = Image.open(p).convert("RGBA").resize((size, size), Image.LANCZOS)
        out.paste(orig, (x, y0), orig)
        out.paste(render(p).convert("RGB"), (x, y0 + size + label))
    path = "/var/minis/attachments/noir_v2.png"
    out.save(path)
    print("sheet:", path, out.size)


def batch(kind=None, limit=None):
    dst = os.path.join(OUT_BASE, "Noir 金.theme", "IconBundles")
    os.makedirs(dst, exist_ok=True)
    fs = sorted(glob.glob(os.path.join(SRC, "*.png")))
    if limit:
        fs = fs[:limit]
    n = 0
    for p in fs:
        out = render(p)
        out.save(os.path.join(dst, os.path.basename(p)))
        n += 1
        if n % 100 == 0:
            print("  ", n, "/", len(fs), flush=True)
    print("done", n, "->", dst)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "sheet"
    if cmd == "sheet":
        sheet()
    elif cmd == "batch":
        batch(limit=int(sys.argv[2]) if len(sys.argv) > 2 else None)
