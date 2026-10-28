"""Draws the Authentik brand files for example.com: python make.py (needs Pillow)."""
import math, random
from PIL import Image, ImageDraw

OUT = __file__.rsplit('make.py', 1)[0]
A, B = '#4f7cff', '#8a5cff'          # accent gradient

# ---- cloud icon (viewBox 64): circles + base, a row of fading dots inside ----
def cloud_svg(defs_id='g'):
    return f'''<defs><linearGradient id="{defs_id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{A}"/><stop offset="1" stop-color="{B}"/></linearGradient></defs>
<g fill="url(#{defs_id})"><circle cx="19" cy="38" r="12"/><circle cx="32" cy="28" r="15"/><circle cx="46" cy="38" r="12"/><rect x="19" y="38" width="27" height="12" rx="0"/><rect x="19" y="26" width="27" height="24"/></g>
<g fill="#fff"><circle cx="22" cy="42" r="3.6" opacity=".95"/><circle cx="32" cy="42" r="2.6" opacity=".8"/><circle cx="40" cy="42" r="1.8" opacity=".65"/><circle cx="46" cy="42" r="1.1" opacity=".5"/></g>'''

open(OUT + 'favicon.svg', 'w').write(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="6 8 52 48">{cloud_svg()}</svg>\n')
open(OUT + 'logo.svg', 'w').write(f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 330 64">
<g transform="translate(-2 0)">{cloud_svg()}</g>
<text x="64" y="43" font-family="Inter, 'Segoe UI', Helvetica, Arial, sans-serif" font-size="30" font-weight="700" fill="#6b7280">example<tspan font-weight="400" fill="{A}">.cloud</tspan></text>
</svg>
''')

# ---- favicon PNG (same shapes, 4x supersampled) ----
def lerp(c1, c2, t):
    return tuple(round(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
def hexrgb(h): return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))
def favicon_png(size):
    S = size * 4
    sc = S / 52
    ox, oy = 6, 8
    mask = Image.new('L', (S, S), 0); d = ImageDraw.Draw(mask)
    def circ(cx, cy, r, im=d, fill=255):
        im.ellipse([(cx - r - ox) * sc, (cy - r - oy) * sc, (cx + r - ox) * sc, (cy + r - oy) * sc], fill=fill)
    for cx, cy, r in ((19, 38, 12), (32, 28, 15), (46, 38, 12)): circ(cx, cy, r)
    d.rectangle([(19 - ox) * sc, (26 - oy) * sc, (46 - ox) * sc, (50 - oy) * sc], fill=255)
    grad = Image.new('RGB', (S, S))
    gd = ImageDraw.Draw(grad)
    c1, c2 = hexrgb(A), hexrgb(B)
    for i in range(2 * S):   # diagonal gradient
        gd.line([(i, 0), (0, i)], fill=lerp(c1, c2, i / (2 * S)), width=2)
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0)); img.paste(grad, (0, 0), mask)
    dd = ImageDraw.Draw(img)
    for cx, cy, r, a in ((22, 42, 3.6, 240), (32, 42, 2.6, 204), (40, 42, 1.8, 166), (46, 42, 1.1, 128)):
        dd.ellipse([(cx - r - ox) * sc, (cy - r - oy) * sc, (cx + r - ox) * sc, (cy + r - oy) * sc], fill=(255, 255, 255, a))
    return img.resize((size, size), Image.LANCZOS)
favicon_png(256).save(OUT + 'favicon.png')
favicon_png(48).save(OUT + 'favicon.ico', sizes=[(16, 16), (32, 32), (48, 48)])

# ---- halftone background: rings around a point left of the image, dots shrink with distance ----
def background(path, bg, tones, W=1920, H=1080, seed=7):
    rnd = random.Random(seed)
    k = 2
    img = Image.new('RGB', (W * k, H * k), bg); d = ImageDraw.Draw(img)
    cx, cy = -260, H * 0.52
    step, R = 27, 1500
    ring = 0; r = 40
    while r < R:
        t = (r - 40) / (R - 40)
        size = 10.5 * (1 - t) ** 1.45
        if size > 0.55:
            n = int(2 * math.pi * r / step)
            off = rnd.random() * 6.28
            for i in range(n):
                a = off + 2 * math.pi * i / n
                x, y = cx + r * math.cos(a), cy + r * math.sin(a)
                if -12 < x < W + 12 and -12 < y < H + 12:
                    tone = tones[(i + ring) % len(tones)]
                    # lighter toward the right edge so it melts into the page
                    f = max(0.0, min(1.0, x / (W * 0.8)))
                    col = lerp(hexrgb(tone), hexrgb(bg), f * 0.55)
                    d.ellipse([(x - size) * k, (y - size) * k, (x + size) * k, (y + size) * k], fill=col)
        ring += 1; r += step * (0.92 + 0.12 * t)
    img.resize((W, H), Image.LANCZOS).save(path, optimize=True)

background(OUT + 'background-light.png', '#ffffff', ['#8e9096', '#c9cbd1'])
background(OUT + 'background-dark.png', '#0e1016', ['#3a4152', '#232837'])
print('ok')
