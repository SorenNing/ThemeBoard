#!/usr/bin/env python3
"""六套完全不同的美术方向。

每套都包含「底 + 字形」两层的重新设计，不只是换线色：
  1 玻璃  Glass     深底 + 玻璃质感浮雕字 + 柔光
  2 霓虹  Neon      纯黑 + 取原色为霓虹发光线条
  3 极简  Minimal   近黑纯色底 + 单一高饱和实心字
  4 纸感  Paper     米白纸纹底 + 墨色线稿（亮色系）
  5 浮雕  Emboss    金属灰底 + 同色凸起浮雕
  6 反色  Invert    取原图主色铺底 + 近黑实心字（撞色）
"""
import os, glob
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from PIL import ImageFont

SRC = "/tmp/icons/iOS26图标_泽哥二编/IconBundles"
OUTDIR = "/var/minis/attachments"
WORK, SIZE = 512, 220
CJK = "/usr/share/fonts/noto/NotoSansCJK-Bold.ttc"


# ---------- 基础 ----------
def gradient(c0, c1, size=SIZE):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)],
               fill=tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3)))
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


def up(img, size):
    return img.resize((size, size), Image.LANCZOS)


def prep(path, work=WORK):
    im = Image.open(path).convert("RGBA").resize((work, work), Image.LANCZOS)
    arr = np.asarray(im).astype(np.float32)
    rgb, alpha = arr[..., :3], arr[..., 3] / 255.0
    w = work
    ring = np.concatenate([arr[4, 8:w-8, :3].reshape(-1, 3), arr[w-5, 8:w-8, :3].reshape(-1, 3),
                           arr[8:w-8, 4, :3].reshape(-1, 3), arr[8:w-8, w-5, :3].reshape(-1, 3)])
    bg = np.median(ring, axis=0) if ring.size else np.array([255., 255., 255.])
    bg_luma = float(bg @ np.array([0.299, 0.587, 0.114], np.float32))

    lum = rgb @ np.array([0.299, 0.587, 0.114], np.float32)
    gray = lum.copy()
    inverted = bg_luma > 215
    if inverted:
        lum = 255.0 - lum
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
    key = Image.fromarray((line > 60).astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.GaussianBlur(0.7))
    line = np.asarray(key).astype(np.float32) / 255.0
    line *= np.asarray(inner_mask(work, int(work * 0.035))).astype(np.float32) / 255.0

    # 主体：与背景色的差
    dist = np.abs(rgb - bg[None, None, :]).max(axis=2)
    body = np.clip((dist - 24) / 88.0, 0, 1)
    body = np.asarray(Image.fromarray((body * 255).astype(np.uint8))
                      .filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
                      ).astype(np.float32) / 255.0
    body *= np.asarray(inner_mask(work, int(work * 0.03))).astype(np.float32) / 255.0

    # 品牌色：取整张图里最饱和的一簇（而不是白字形）
    flat = rgb[alpha > 0.6].reshape(-1, 3)
    if len(flat) < 50:
        flat = rgb.reshape(-1, 3)
    mx = flat.max(axis=1)
    mn = flat.min(axis=1)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1), 0)
    hot = flat[sat > max(0.35, float(np.percentile(sat, 92)))]
    if len(hot) < 20:
        hot = flat[sat > 0.2]
    accent = hot.mean(axis=0) if len(hot) > 20 else bg
    accent = np.clip((accent - accent.mean()) * 1.35 + accent.mean(), 0, 255)

    return dict(rgb=rgb, alpha=alpha, lum=lum, gray=gray, line=line, body=body,
                bg=bg, accent=accent, inverted=inverted, size=work,
                cov=float(body.mean()))


def compose(layers, rim=None, rim_alpha=190):
    """layers: list of (RGB array 或 Image, alpha 0..1 array)"""
    base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 255))
    for core, a in layers:
        c = Image.fromarray(np.clip(core, 0, 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS)
        al = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS)
        base.paste(c, (0, 0), al)
    if rim:
        d = ImageDraw.Draw(base)
        d.rounded_rectangle([1, 1, SIZE - 2, SIZE - 2], radius=int(SIZE * 0.2237),
                            outline=rim + (rim_alpha,), width=2)
    base.putalpha(rounded_mask(SIZE, int(SIZE * 0.2237)))
    return base


def solid_rgb(rgb_arr):
    return np.ones((SIZE, SIZE, 3), np.float32) * np.array(rgb_arr, np.float32)


def blur_arr(a, r):
    im = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))
    return np.asarray(im).astype(np.float32) / 255.0


def shift(a, dx, dy):
    out = np.zeros_like(a)
    h, w = a.shape
    xs0, xs1 = max(0, dx), min(w, w + dx)
    ys0, ys1 = max(0, dy), min(h, h + dy)
    out[ys0:ys1, xs0:xs1] = a[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]
    return out


# ---------- 六种风格 ----------
def s_glass(d):
    """磨砂玻璃砖：原图压暗 + 大模糊打底，白色线稿浮在上面"""
    src = Image.fromarray(np.clip(d["rgb"], 0, 255).astype(np.uint8)).resize((SIZE, SIZE), Image.LANCZOS)
    frost = src.filter(ImageFilter.GaussianBlur(SIZE * 0.10))
    fa = np.asarray(frost).astype(np.float32) * 0.34 + np.array([10, 10, 13], np.float32) * 0.66
    line = d["line"]
    hi = np.clip(shift(line, -2, -2) - line, 0, 1)
    layers = [(fa, np.ones((SIZE, SIZE))),
              (solid_rgb((150, 150, 158)), line * 0.35),
              (solid_rgb((255, 255, 255)), line * 0.95),
              (solid_rgb((255, 255, 255)), hi * 0.55)]
    out = compose(layers, rim=(255, 255, 255), rim_alpha=80)
    g = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ImageDraw.Draw(g).ellipse([-SIZE*.3, -SIZE*.62, SIZE*1.3, SIZE*.45], fill=(255, 255, 255, 14))
    g = g.filter(ImageFilter.GaussianBlur(SIZE*0.06))
    return Image.alpha_composite(out, g)


def s_neon(d):
    acc = d["accent"]
    line = d["line"]
    glow = blur_arr(line, 9)
    glow2 = blur_arr(line, 3)
    base = compose([(np.zeros((SIZE, SIZE, 3)) + np.array([4, 4, 6]), np.ones((SIZE, SIZE))),
                    (solid_rgb(acc * 0.55), glow * 0.75),
                    (solid_rgb(acc), glow2 * 0.9),
                    (solid_rgb(np.clip(acc * 0.35 + 200, 0, 255)), line)], rim=tuple(int(v) for v in acc), rim_alpha=120)
    return base


def s_minimal(d):
    acc = np.clip(d["accent"] * 1.15 + 20, 0, 255)
    base = np.zeros((SIZE, SIZE, 3)) + np.array([12, 12, 14])
    if d["cov"] < 0.62:
        shape, a = solid_rgb(acc), d["body"]
    else:
        shape, a = solid_rgb(acc), d["line"] * 0.95
    return compose([(base, np.ones((SIZE, SIZE))), (shape, a)], rim=(52, 52, 58), rim_alpha=180)


def s_paper(d):
    rng = np.random.default_rng(7)
    noise = rng.normal(0, 5.2, (SIZE, SIZE, 1)).repeat(3, axis=2)
    paper = np.clip(np.array([244, 240, 231], np.float32) + noise, 0, 255)
    ink = solid_rgb((34, 32, 30))
    line = d["line"]
    body = d["body"]
    # 墨线 + 轻微墨块
    return compose([(paper, np.ones((SIZE, SIZE))),
                    (ink, line * 0.95),
                    (solid_rgb((90, 86, 80)), body * 0.10)], rim=(198, 192, 180), rim_alpha=220)


def s_emboss(d):
    line = d["line"]
    base = gradient((52, 53, 58), (26, 27, 31)).convert("RGB")
    hi = np.clip(shift(line, -2, -2), 0, 1)
    lo = np.clip(shift(line, 2, 2), 0, 1)
    layers = [(np.asarray(base).astype(np.float32), np.ones((SIZE, SIZE))),
              (solid_rgb((8, 8, 10)), lo * 0.95),
              (solid_rgb((126, 130, 140)), hi * 0.9),
              (solid_rgb((70, 72, 78)), line * 0.55)]
    return compose(layers, rim=(105, 108, 116), rim_alpha=160)


def s_invert(d):
    bright = np.clip(d["bg"] * 1.0 + 34, 0, 255)
    if d["cov"] < 0.62:
        shape, a = solid_rgb((16, 15, 18)), d["body"]
    else:
        shape, a = solid_rgb((16, 15, 18)), d["line"] * 0.98
    return compose([(solid_rgb(bright), np.ones((SIZE, SIZE))), (shape, a)],
                   rim=tuple(int(v) for v in np.clip(bright * 0.82, 0, 255)), rim_alpha=110)


STYLES = [
    ("玻璃 Glass", s_glass),
    ("霓虹 Neon", s_neon),
    ("极简 Minimal", s_minimal),
    ("纸感 Paper", s_paper),
    ("浮雕 Emboss", s_emboss),
    ("反色 Invert", s_invert),
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
        cand = fs[(len(out) * 53) % len(fs)]
        if cand not in out:
            out.append(cand)
    return out[:n]


def make_sheet(name, fn, paths, prepared):
    cols, pad, head = 4, 14, 54
    rows = (len(paths) + cols - 1) // cols
    W = pad + cols * (SIZE + pad)
    H = head + rows * (SIZE + pad) + pad
    out = Image.new("RGB", (W, H), (14, 14, 15))
    d = ImageDraw.Draw(out)
    f = ImageFont.truetype(CJK, 28)
    d.text((pad + 2, 12), name, font=f, fill=(240, 240, 242))
    for i, dd in enumerate(prepared):
        r, c = divmod(i, cols)
        out.paste(fn(dd).convert("RGB"), (pad + c * (SIZE + pad), head + r * (SIZE + pad)))
    path = os.path.join(OUTDIR, "style_%s.png" % name.split()[0])
    out.save(path)
    return path


def overview(paths, prepared, results):
    cols, pad, head = 8, 10, 40
    thumb = 150
    rows = len(results)
    W = pad + cols * (thumb + pad)
    H = head + rows * (thumb + pad + 24)
    out = Image.new("RGB", (W, H), (14, 14, 15))
    d = ImageDraw.Draw(out)
    f = ImageFont.truetype(CJK, 17)
    for r, (name, imgs) in enumerate(results):
        y = head + r * (thumb + pad + 24)
        d.text((pad, y - 22), name, font=f, fill=(230, 230, 234))
        for c, im in enumerate(imgs):
            out.paste(im.convert("RGB").resize((thumb, thumb), Image.LANCZOS), (pad + c * (thumb + pad), y))
    p = os.path.join(OUTDIR, "style_overview.png")
    out.save(p)
    return p


if __name__ == "__main__":
    paths = sample_paths(8)
    prepared = [prep(p) for p in paths]
    results = []
    for name, fn in STYLES:
        imgs = [fn(d) for d in prepared]
        p = make_sheet(name, fn, paths, prepared)
        print("sheet:", p)
        results.append((name, imgs))
    print("overview:", overview(paths, prepared, results))
