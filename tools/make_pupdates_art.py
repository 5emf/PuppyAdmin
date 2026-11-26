"""Original art for Pupdates (plain geometric shapes drawn here with Pillow at 4x and downsampled;
the glyph style matches tools/make_sao_art.py).

Round SAO-style menu icons in three states:
  normal  - light plate with a grey ring and a grey glyph
  hover   - white plate with an orange glyph
  chosen  - orange plate with a white glyph and a thin orange ring around it
Desktop (pupdates/pupdates_app/art_data.py): base64 PNGs whose alpha is cut to fully on / off,
  because the window's see-through colour (Tk -transparentcolor) cannot show half-transparent pixels.
Android (pupdates/android/app/src/main/res/drawable-nodpi/): the same icons with smooth edges,
  plus the launcher icon in mipmap-*.
Also pupdates/Pupdates.ico (the exe icon).
Run: python3 tools/make_pupdates_art.py
"""
import base64
import io
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_sao_art  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DESK = os.path.join(ROOT, "pupdates", "pupdates_app", "art_data.py")
RES = os.path.join(ROOT, "pupdates", "android", "app", "src", "main", "res")
ICO = os.path.join(ROOT, "pupdates", "Pupdates.ico")
S = 4
ICONS = ("compose", "updates", "tags", "games", "whitelist", "settings", "picture", "send", "close")
STATES = ("normal", "hover", "chosen")
ORANGE = (245, 155, 40)
GREY_GLYPH = (112, 116, 126)


def glyph(name, size):
    if name in ("whitelist", "settings", "close", "tags", "games"):
        return make_sao_art.icon({"whitelist": "alts", "settings": "config", "close": "close", "tags": "look", "games": "games"}[name], size)
    big = size * S
    img = Image.new("L", (big, big), 0)
    d = ImageDraw.Draw(img)
    c = big / 2
    w = max(2, int(big * 0.075))
    r = big * 0.36
    if name == "compose":  # a pencil leaning right
        a = math.radians(-45)
        ux, uy = math.cos(a), math.sin(a)          # along the pencil
        vx, vy = -uy, ux                           # across it
        half, L = r * 0.26, r * 1.25

        def p(t, s):
            return (c + ux * t + vx * s, c + uy * t + vy * s)
        body = [p(-L * 0.45, -half), p(L * 0.75, -half), p(L * 0.75, half), p(-L * 0.45, half)]
        d.line(body + [body[0]], fill=255, width=w, joint="curve")
        tip = [p(-L * 0.45, -half), p(-L * 0.85, 0), p(-L * 0.45, half)]
        d.line(tip, fill=255, width=w, joint="curve")
        d.line([p(L * 0.48, -half), p(L * 0.48, half)], fill=255, width=w)
    elif name == "updates":  # a circular arrow
        box = [c - r * 0.85, c - r * 0.85, c + r * 0.85, c + r * 0.85]
        d.arc(box, 40, 330, fill=255, width=w)
        a = math.radians(330)
        hx, hy = c + math.cos(a) * r * 0.85, c + math.sin(a) * r * 0.85
        d.polygon([(hx - r * 0.38, hy - r * 0.05), (hx + r * 0.28, hy - r * 0.18), (hx + r * 0.02, hy + r * 0.4)], fill=255)
    elif name == "picture":  # a frame, a hill and a sun
        d.rectangle([c - r, c - r * 0.72, c + r, c + r * 0.72], outline=255, width=w)
        d.line([(c - r * 0.8, c + r * 0.5), (c - r * 0.25, c - r * 0.1), (c + r * 0.15, c + r * 0.3),
                (c + r * 0.42, c + r * 0.05), (c + r * 0.8, c + r * 0.5)], fill=255, width=w, joint="curve")
        d.ellipse([c + r * 0.25, c - r * 0.5, c + r * 0.55, c - r * 0.2], fill=255)
    elif name == "send":  # a paper plane
        pts = [(c - r, c - r * 0.1), (c + r, c - r * 0.75), (c + r * 0.2, c + r * 0.85), (c - r * 0.1, c + r * 0.2)]
        d.line(pts + [pts[0]], fill=255, width=w, joint="curve")
        d.line([(c - r * 0.1, c + r * 0.2), (c + r, c - r * 0.75)], fill=255, width=w)
    return img.resize((size, size), Image.LANCZOS)


def plate(name, state, size):
    """One round icon, RGBA, size x size (the chosen ring fits inside)."""
    big = size * S
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    ring = big * 0.06
    inner = [ring * 1.9, ring * 1.9, big - ring * 1.9, big - ring * 1.9]
    if state == "chosen":
        d.ellipse([ring * 0.3, ring * 0.3, big - ring * 0.3, big - ring * 0.3], outline=ORANGE + (255,), width=int(ring * 0.55))
        d.ellipse(inner, fill=ORANGE + (255,), outline=(255, 255, 255, 255), width=int(ring * 0.5))
        colour = (255, 255, 255)
    elif state == "hover":
        d.ellipse(inner, fill=(255, 255, 255, 255), outline=ORANGE + (255,), width=int(ring * 0.5))
        colour = ORANGE
    else:
        d.ellipse(inner, fill=(242, 243, 245, 255), outline=(186, 190, 198, 255), width=int(ring * 0.5))
        colour = GREY_GLYPH
    img = img.resize((size, size), Image.LANCZOS)
    g = glyph(name, int(size * 0.62))
    layer = Image.new("RGBA", g.size, colour + (255,))
    layer.putalpha(g)
    off = (size - g.size[0]) // 2
    img.alpha_composite(layer, (off, off))
    return img


def hard_alpha(img):
    """Alpha cut to on / off (for Tk's see-through colour): an edge pixel is either drawn fully or not at all."""
    out = img.copy()
    a = out.getchannel("A").point(lambda v: 255 if v >= 128 else 0)
    out.putalpha(a)
    return out


def png_b64(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def app_icon(size):
    """Pupdates' own icon: an orange disc with a white speech bubble and a P."""
    big = size * S
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse([big * 0.03, big * 0.03, big * 0.97, big * 0.97], fill=ORANGE + (255,))
    bx0, by0, bx1, by1 = big * 0.22, big * 0.24, big * 0.78, big * 0.66
    d.rounded_rectangle([bx0, by0, bx1, by1], radius=big * 0.1, fill=(255, 255, 255, 255))
    d.polygon([(big * 0.34, by1 - 2), (big * 0.30, big * 0.80), (big * 0.48, by1 - 2)], fill=(255, 255, 255, 255))
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", int(big * 0.34))
    except OSError:
        font = ImageFont.load_default(int(big * 0.34))
    d.text(((bx0 + bx1) / 2, (by0 + by1) / 2), "P", font=font, fill=ORANGE + (255,), anchor="mm")
    return img.resize((size, size), Image.LANCZOS)


def main():
    desk = {}
    for name in ICONS:
        for state in STATES:
            desk["%s_%s" % (name, state)] = png_b64(hard_alpha(plate(name, state, 52)))
    desk["logo"] = png_b64(hard_alpha(app_icon(40)))
    with open(DESK, "w", encoding="utf-8") as f:
        f.write('"""Pupdates menu icons (made by tools/make_pupdates_art.py; do not edit)."""\n')
        f.write("ICONS = {\n")
        for k in sorted(desk):
            f.write("    %r: %r,\n" % (k, desk[k]))
        f.write("}\n")
    draw = os.path.join(RES, "drawable-nodpi")
    os.makedirs(draw, exist_ok=True)
    for name in ICONS:
        for state in STATES:
            plate(name, state, 144).save(os.path.join(draw, "ic_%s_%s.png" % (name, state)), optimize=True)
    for folder, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        out = os.path.join(RES, "mipmap-" + folder)
        os.makedirs(out, exist_ok=True)
        app_icon(px).save(os.path.join(out, "ic_launcher.png"), optimize=True)
    app_icon(256).save(ICO, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("wrote", DESK, RES, ICO)


if __name__ == "__main__":
    main()
