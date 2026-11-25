"""Original art for Puppy Admin's self HUD and the Kingdom Hearts style menus.

Drawn with Pillow at 4x and downsampled (like the game sheets). Writes:
  assets/hud/panel_v1.png    - 9-slice panel: deep navy fill, light-blue rim, thin inner line, notched corners
  assets/hud/header_v1.png   - title strip: a glowing line that fades out to the right
  assets/hud/ringback_v1.png - dark ring behind the circular HP segments, with a light outer rim
  Themeable layers (white / grey, tinted in Roblox with ImageColor3 so they follow every theme change):
  assets/hud/panel_fill_v1.png, panel_rim_v1.png - panel body (theme surface) and its lines (theme accent)
  assets/hud/ring_fill_v1.png,  ring_rim_v1.png  - ring backing body and its rims
  assets/hud/header_tint_v1.png                  - the title strip in grey (theme accent)
  assets/hud/pill_v1.png                         - glossy capsule behind window titles (white, tinted)
  assets/hud/underline_v1.png                    - thin line under titles that fades out to the right (white, tinted)
Run: python3 tools/make_hud_art.py   (bump the _v names when the art changes)
"""
import os

from PIL import Image, ImageDraw, ImageFilter

S = 4
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "hud")
NAVY_TOP, NAVY_BOT = (22, 34, 82), (8, 12, 34)
RIM, INNER = (120, 175, 255), (70, 110, 200)


def vgrad(w, h, top, bot, alpha=235):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        for x in range(w):
            px[x, y] = c + (alpha,)
    return img


def notched(draw, box, cut, **kw):
    x0, y0, x1, y1 = box
    pts = [(x0 + cut, y0), (x1 - cut, y0), (x1, y0 + cut), (x1, y1 - cut), (x1 - cut, y1), (x0 + cut, y1), (x0, y1 - cut), (x0, y0 + cut)]
    draw.polygon(pts, **kw)
    return pts


def panel():
    W = H = 96 * S
    cut = 10 * S
    mask = Image.new("L", (W, H), 0)
    notched(ImageDraw.Draw(mask), (0, 0, W - 1, H - 1), cut, fill=255)
    fill = vgrad(W, H, NAVY_TOP, NAVY_BOT)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.paste(fill, (0, 0), mask)
    d = ImageDraw.Draw(img)
    pts = notched(d, (S, S, W - 1 - S, H - 1 - S), cut, outline=None)
    d.line(pts + [pts[0]], fill=RIM + (255,), width=2 * S)
    inset = 6 * S
    pts2 = notched(d, (inset, inset, W - 1 - inset, H - 1 - inset), cut - 3 * S, outline=None)
    d.line(pts2 + [pts2[0]], fill=INNER + (170,), width=S)
    # small diamonds on the corners of the inner line
    for (x, y) in ((inset + 5 * S, inset + 5 * S), (W - inset - 5 * S, inset + 5 * S),
                   (inset + 5 * S, H - inset - 5 * S), (W - inset - 5 * S, H - inset - 5 * S)):
        r = 2 * S
        d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], fill=RIM + (230,))
    return img.resize((96, 96), Image.LANCZOS)


def header():
    W, H = 256 * S, 32 * S
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    y = H - 6 * S
    for x in range(W):
        a = int(255 * max(0.0, 1 - x / W) ** 1.4)
        g.line([(x, y - 2 * S), (x, y + 2 * S)], fill=RIM + (a // 2,))
    glow = glow.filter(ImageFilter.GaussianBlur(3 * S))
    img.alpha_composite(glow)
    d = ImageDraw.Draw(img)
    for x in range(W):
        a = int(255 * max(0.0, 1 - x / W) ** 1.2)
        d.line([(x, y - S // 2), (x, y + S // 2)], fill=(200, 225, 255, a))
    # a faint band behind the title text
    band = vgrad(W, y - 4 * S, (40, 70, 150), (20, 35, 90), alpha=0)
    bpx = band.load()
    for yy in range(band.size[1]):
        for xx in range(W):
            r, gg, b, _ = bpx[xx, yy]
            bpx[xx, yy] = (r, gg, b, int(110 * max(0.0, 1 - xx / (W * 0.8))))
    img.alpha_composite(band, (0, 2 * S))
    return img.resize((256, 32), Image.LANCZOS)


def ringback():
    W = 160 * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = W / 2
    R = 78 * S
    d.ellipse([c - R, c - R, c + R, c + R], fill=(10, 14, 36, 245))
    d.ellipse([c - R, c - R, c + R, c + R], outline=RIM + (255,), width=3 * S)
    r2 = 58 * S
    d.ellipse([c - r2, c - r2, c + r2, c + r2], outline=INNER + (200,), width=2 * S)
    return img.resize((160, 160), Image.LANCZOS)


def tintable(img):
    """Grey by luminance, stretched so the brightest pixel is white; alpha kept."""
    img = img.convert("RGBA")
    px = img.load()
    w, h = img.size
    peak = 1
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 40:
                peak = max(peak, 0.299 * r + 0.587 * g + 0.114 * b)
    out = Image.new("RGBA", (w, h))
    opx = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            v = min(255, int(round((0.299 * r + 0.587 * g + 0.114 * b) * 255 / peak)))
            opx[x, y] = (v, v, v, a)
    return out


WHITE_TOP, WHITE_BOT = (255, 255, 255), (165, 165, 165)


def panel_fill():
    W = H = 96 * S
    cut = 10 * S
    mask = Image.new("L", (W, H), 0)
    notched(ImageDraw.Draw(mask), (0, 0, W - 1, H - 1), cut, fill=255)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.paste(vgrad(W, H, WHITE_TOP, WHITE_BOT, alpha=240), (0, 0), mask)
    return img.resize((96, 96), Image.LANCZOS)


def panel_rim():
    W = H = 96 * S
    cut = 10 * S
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pts = notched(d, (S, S, W - 1 - S, H - 1 - S), cut, outline=None)
    d.line(pts + [pts[0]], fill=(255, 255, 255, 255), width=2 * S)
    inset = 6 * S
    pts2 = notched(d, (inset, inset, W - 1 - inset, H - 1 - inset), cut - 3 * S, outline=None)
    d.line(pts2 + [pts2[0]], fill=(255, 255, 255, 150), width=S)
    for (x, y) in ((inset + 5 * S, inset + 5 * S), (W - inset - 5 * S, inset + 5 * S),
                   (inset + 5 * S, H - inset - 5 * S), (W - inset - 5 * S, H - inset - 5 * S)):
        r = 2 * S
        d.polygon([(x, y - r), (x + r, y), (x, y + r), (x - r, y)], fill=(255, 255, 255, 230))
    return img.resize((96, 96), Image.LANCZOS)


def ring_fill():
    W = 160 * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    c, R = W / 2, 78 * S
    ImageDraw.Draw(img).ellipse([c - R, c - R, c + R, c + R], fill=(255, 255, 255, 245))
    return img.resize((160, 160), Image.LANCZOS)


def ring_rim():
    W = 160 * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c, R, r2 = W / 2, 78 * S, 58 * S
    d.ellipse([c - R, c - R, c + R, c + R], outline=(255, 255, 255, 255), width=3 * S)
    d.ellipse([c - r2, c - r2, c + r2, c + r2], outline=(255, 255, 255, 170), width=2 * S)
    return img.resize((160, 160), Image.LANCZOS)


def pill():
    W, H = 256 * S, 48 * S
    r = H // 2
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, H - 1], radius=r, fill=255)
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    img.paste(vgrad(W, H, (255, 255, 255), (150, 150, 150), alpha=255), (0, 0), mask)
    # gloss: a brighter band over the top half
    gloss = Image.new("L", (W, H), 0)
    ImageDraw.Draw(gloss).rounded_rectangle([r // 2, 2 * S, W - 1 - r // 2, H // 2], radius=r // 2, fill=90)
    gloss = gloss.filter(ImageFilter.GaussianBlur(2 * S))
    white = Image.new("RGBA", (W, H), (255, 255, 255, 0))
    white.putalpha(Image.composite(gloss, Image.new("L", (W, H), 0), mask))
    img.alpha_composite(white)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([S, S, W - 1 - S, H - 1 - S], radius=r - S, outline=(255, 255, 255, 230), width=2 * S)
    return img.resize((256, 48), Image.LANCZOS)


def underline():
    W, H = 256 * S, 8 * S
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    for x in range(W):
        a = int(255 * max(0.0, 1 - x / W) ** 0.8)
        d.line([(x, 3 * S), (x, 5 * S)], fill=(255, 255, 255, a))
    return img.filter(ImageFilter.GaussianBlur(S // 2)).resize((256, 8), Image.LANCZOS)


os.makedirs(OUT, exist_ok=True)
for name, fn in (("pill_v1.png", pill), ("underline_v1.png", underline), ("panel_v1.png", panel), ("header_v1.png", header), ("ringback_v1.png", ringback),
                 ("panel_fill_v1.png", panel_fill), ("panel_rim_v1.png", panel_rim),
                 ("ring_fill_v1.png", ring_fill), ("ring_rim_v1.png", ring_rim),
                 ("header_tint_v1.png", lambda: tintable(header()))):
    fn().save(os.path.join(OUT, name), optimize=True)
    print("wrote", name)
