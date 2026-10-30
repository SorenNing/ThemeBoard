#!/usr/bin/env python3
"""把彩色图标转成 Noir 风格（深底 + 金）。

三种技法：
  duotone    明暗映射成金色（保留原始形体，最耐看）
  edge       边缘检测成金线稿（最接近参考图）
  silhouette 主体剪影填金（最简洁）

用法：
  python3 noirify.py sheet          生成对比样张
  python3 noirify.py batch <技法>   批量转换整个主题包
"""
import os, sys, glob, math, random
from PIL import Image, ImageDraw, ImageFilter, ImageChops, ImageStat

SRC = "/tmp/icons/iOS26图标_泽哥二编/IconBundles"
OUT_BASE = "/var/minis/workspace/themeboard/noir-themes"
GOLD_HI = (246, 222, 168)
GOLD_MID = (188, 148, 84)
GOLD_LO = (74, 56, 30)
BG_TOP = (26, 24, 21)
BG_BOT = (9, 8, 8)
RIM = (212, 175, 105)


def bg_gradient(size):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    return img


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def load(path, size=180):
    im = Image.open(path).convert("RGBA")
    im = im.resize((size, size), Image.LANCZOS)
    return im


def dominant_bg(im):
    """取四角内侧一圈的中位色，作为图标背景色"""
    w, h = im.size
    px = im.load()
    samples = []
    for i in range(6, w - 6, max(1, (w - 12) // 12)):
        for (x, y) in ((i, 6), (i, h - 7), (6, i), (w - 7, i)):
            r, g, b, a = px[x, y]
            if a > 200:
                samples.append((r, g, b))
    if not samples:
        return (255, 255, 255)
    samples.sort(key=lambda c: c[0] + c[1] + c[2])
    return samples[len(samples) // 2]


def luminance(im):
    return im.convert("L")


def gold_ramp(lum, gamma=1.0):
    """单通道亮度图 → 金色 RGB"""
    lut_r, lut_g, lut_b = [], [], []
    for i in range(256):
        t = (i / 255.0) ** gamma
        if t < 0.5:
            k = t / 0.5
            c = tuple(int(GOLD_LO[j] + (GOLD_MID[j] - GOLD_LO[j]) * k) for j in range(3))
        else:
            k = (t - 0.5) / 0.5
            c = tuple(int(GOLD_MID[j] + (GOLD_HI[j] - GOLD_MID[j]) * k) for j in range(3))
        lut_r.append(c[0]); lut_g.append(c[1]); lut_b.append(c[2])
    out = Image.merge("RGB", (lum.point(lut_r), lum.point(lut_g), lum.point(lut_b)))
    return out


def finish(core_rgb, alpha, size=180, rim_alpha=200):
    """把核心图叠到深色底上，加圆角与金色描边"""
    base = bg_gradient(size).convert("RGBA")
    base.paste(core_rgb, (0, 0), alpha)
    d = ImageDraw.Draw(base)
    r = int(size * 0.2237)
    d.rounded_rectangle([1, 1, size - 2, size - 2], radius=r, outline=RIM + (rim_alpha,), width=2)
    # 顶部微光
    gloss = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    gd.ellipse([-size * 0.3, -size * 0.55, size * 1.3, size * 0.42], fill=(255, 235, 190, 16))
    gloss = gloss.filter(ImageFilter.GaussianBlur(size * 0.05))
    base = Image.alpha_composite(base, gloss)
    base.putalpha(rounded_mask(size, r))
    return base


def render_duotone(im):
    size = im.size[0]
    bg = dominant_bg(im)
    lum = luminance(im)
    # 背景亮 → 反相，保证"底暗字亮"
    if sum(bg) / 3 > 150:
        lum = ImageChops.invert(lum)
    # 提高对比，压掉背景
    lum = lum.point(lambda v: max(0, min(255, int((v - 40) * 1.55))))
    core = gold_ramp(lum, gamma=1.05)
    return finish(core, im.getchannel("A"), size)


def render_edge(im):
    size = im.size[0]
    bg = dominant_bg(im)
    lum = luminance(im)
    if sum(bg) / 3 > 150:
        lum = ImageChops.invert(lum)
    e = lum.filter(ImageFilter.GaussianBlur(1.0)).filter(ImageFilter.FIND_EDGES)
    e = e.point(lambda v: 255 if v > 46 else 0)
    e = e.filter(ImageFilter.MaxFilter(3))          # 加粗
    e = e.filter(ImageFilter.GaussianBlur(0.6))     # 柔化
    # 亮度作为金的浓淡
    amt = e.point(lambda v: int(v * 0.92))
    core = gold_ramp(amt, gamma=0.9)
    # 用边缘图当 alpha
    alpha = Image.composite(amt, Image.new("L", (size, size), 0), im.getchannel("A").point(lambda v: 255 if v > 32 else 0))
    return finish(core, alpha, size, rim_alpha=210)


def render_silhouette(im):
    size = im.size[0]
    bg = dominant_bg(im)
    px_im = im.convert("RGB")
    # 与背景色的距离
    diff = ImageChops.difference(px_im, Image.new("RGB", (size, size), bg)).convert("L")
    diff = diff.filter(ImageFilter.GaussianBlur(0.8))
    mask = diff.point(lambda v: 255 if v > 52 else 0)
    mask = mask.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    mask = mask.filter(ImageFilter.GaussianBlur(0.5))
    alpha = Image.composite(mask, Image.new("L", (size, size), 0), im.getchannel("A").point(lambda v: 255 if v > 32 else 0))
    core = gold_ramp(alpha, gamma=0.85)
    return finish(core, alpha, size)


RENDERERS = {"duotone": render_duotone, "edge": render_edge, "silhouette": render_silhouette}


def sample_icons(n=8):
    fs = sorted(glob.glob(os.path.join(SRC, "*.png")))
    # 挑有辨识度的常见 app
    want = ["com.apple.mobilesafari", "com.apple.MobileSMS", "com.apple.Preferences",
            "com.tencent.xin", "com.taobao.taobao4iphone", "com.ss.iphone.ugc.Aweme",
            "com.netease.cloudmusic", "tv.danmaku.bilianime"]
    picked = []
    for w in want:
        for f in fs:
            if os.path.basename(f).split("@")[0] == w + ".png" or os.path.basename(f) == w + ".png":
                picked.append(f); break
    random.seed(3)
    while len(picked) < n:
        f = random.choice(fs)
        if f not in picked:
            picked.append(f)
    return picked[:n]


def sheet():
    icons = sample_icons(8)
    cols, size, pad, label = len(icons), 180, 14, 26
    rows = list(RENDERERS.keys())
    W = pad + cols * (size + pad)
    H = label + pad + len(rows) * (size + pad + label)
    out = Image.new("RGB", (W, H), (18, 17, 16))
    d = ImageDraw.Draw(out)
    from PIL import ImageFont
    f = ImageFont.truetype("/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf", 18)
    for r, name in enumerate(rows):
        y = label + pad + r * (size + pad + label)
        d.text((pad, y - 22), name, font=f, fill=(230, 210, 170))
        for c, p in enumerate(icons):
            im = load(p, size)
            out.paste(RENDERERS[name](im).convert("RGB"), (pad + c * (size + pad), y))
    # 原图对照行
    d.text((pad, 4), "original", font=f, fill=(150, 150, 150))
    path = "/var/minis/attachments/noir_compare.png"
    out.save(path)
    print("sheet:", path, out.size)


def batch(kind, limit=None):
    fn = RENDERERS[kind]
    dst = os.path.join(OUT_BASE, "Noir 金.theme", "IconBundles")
    os.makedirs(dst, exist_ok=True)
    fs = sorted(glob.glob(os.path.join(SRC, "*.png")))
    if limit: fs = fs[:limit]
    done = 0
    for i, p in enumerate(fs):
        name = os.path.basename(p)
        im = load(p, 180)
        out = fn(im)
        out.save(os.path.join(dst, name))
        done += 1
        if done % 100 == 0:
            print("  ", done, "/", len(fs), flush=True)
    print("done", done, "->", dst)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "sheet"
    if cmd == "sheet":
        sheet()
    elif cmd == "batch":
        batch(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else None)
