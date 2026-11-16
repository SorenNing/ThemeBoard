#!/usr/bin/env python3
"""Reproduce selected backdrop 04 without the decorative UI-like rectangles."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageEnhance

def render():
    width, height = 1290, 2796
    strip = Image.new('RGB', (1, height))
    top, bottom = (225, 222, 230), (195, 196, 211)
    rows = []
    for y in range(height):
        t = y / (height - 1)
        t = t * t * (3 - 2 * t)
        rows.append(tuple(round(a * (1 - t) + b * t) for a, b in zip(top, bottom)))
    strip.putdata(rows)
    image = strip.resize((width, height)).convert('RGBA')
    layer = Image.new('RGBA', image.size)
    draw = ImageDraw.Draw(layer)
    for x in [90, 330, 600, 870, 1130]:
        draw.line((x, -50, x + 80, height + 50), fill=(74, 75, 98, 34), width=5)
    for y in [260, 720, 1180, 1640, 2100, 2560]:
        draw.line((-50, y, width + 50, y + 25), fill=(255, 255, 255, 48), width=7)
    draw.polygon([(0, height), (0, 2110), (370, 1870), (760, 2110), (1290, 1820), (1290, height)], fill=(83, 85, 106, 24))
    draw.line([(0, 1540), (250, 1490), (530, 1520), (790, 1460), (1290, 1500)], fill=(130, 105, 126, 55), width=5)
    light = Image.alpha_composite(image, layer).convert('RGB')
    # Deterministic fine grain, avoiding random resource churn on each run.
    import random
    rng = random.Random(20261117)
    noise = Image.frombytes('L', (width, height), rng.randbytes(width * height))
    lut_grain = [max(0, min(255, round(128 + (value - 127.5) * 0.12))) for value in range(256)]
    noise = noise.point(lut_grain)
    light = Image.blend(light, Image.merge('RGB', (noise, noise, noise)), 0.042)
    quiet = ImageEnhance.Color(light).enhance(0.55)
    lut = [max(14, min(62, round(20 + (v - 180) * 0.48))) for v in range(256)]
    dark = quiet.point(lut * 3)
    dest = Path(__file__).resolve().parents[1] / 'app/Resources'
    light.save(dest / 'Backdrop04-light.jpg', quality=92, subsampling=0)
    dark.save(dest / 'Backdrop04-dark.jpg', quality=94, subsampling=0)

if __name__ == '__main__':
    render()
