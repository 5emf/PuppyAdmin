"""Draws the Puppy Companion icon (a paw print on a blue tile) with Pillow.

Writes companion/assets/PuppyCompanion.ico (the .exe icon) and
companion/puppy_companion/icon_data.py (PNG copies the window uses).
Run from the repository root:  python companion/tools/make_icon.py
"""
import base64
import io
import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIG = 1024  # drawn at 4x of the largest size, then downsampled


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def draw():
    top, bottom = (110, 184, 255), (38, 104, 214)
    tile = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    grad = Image.new("RGBA", (BIG, BIG))
    gd = ImageDraw.Draw(grad)
    for y in range(BIG):
        gd.line([(0, y), (BIG, y)], fill=lerp(top, bottom, y / (BIG - 1)) + (255,))
    mask = Image.new("L", (BIG, BIG), 0)
    pad = 40
    ImageDraw.Draw(mask).rounded_rectangle([pad, pad, BIG - pad, BIG - pad], radius=230, fill=255)
    tile.paste(grad, (0, 0), mask)

    # soft top highlight
    shine = Image.new("L", (BIG, BIG), 0)
    ImageDraw.Draw(shine).ellipse([-260, -700, BIG + 260, 430], fill=46)
    shine = shine.filter(ImageFilter.GaussianBlur(70))
    shine = Image.composite(shine, Image.new("L", (BIG, BIG), 0), mask)
    tile = Image.composite(Image.new("RGBA", (BIG, BIG), (255, 255, 255, 255)), tile, shine.point(lambda v: v))
    tile.putalpha(mask)

    # paw: one main pad and four toes, with a soft shadow
    paw = Image.new("L", (BIG, BIG), 0)
    pd = ImageDraw.Draw(paw)
    cx, cy = BIG // 2, BIG // 2 + 90
    # main pad: three overlapping lobes (two low, one high) make the usual rounded-triangle pad
    for dx, dy, rx, ry in ((-100, 45, 150, 130), (100, 45, 150, 130), (0, -45, 150, 128)):
        pd.ellipse([cx + dx - rx, cy + dy - ry, cx + dx + rx, cy + dy + ry], fill=255)
    for dx, dy, rx, ry in ((-268, -205, 80, 100), (-104, -322, 86, 110), (104, -322, 86, 110), (268, -205, 80, 100)):
        pd.ellipse([cx + dx - rx, cy + dy - ry, cx + dx + rx, cy + dy + ry], fill=255)

    shadow = paw.filter(ImageFilter.GaussianBlur(26)).point(lambda v: v * 0.45)
    shadow_img = Image.new("RGBA", (BIG, BIG), (10, 30, 80, 255))
    shadow_img.putalpha(Image.composite(shadow, Image.new("L", (BIG, BIG), 0), mask))
    out = Image.alpha_composite(tile, Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0)))
    offset = Image.new("RGBA", (BIG, BIG), (0, 0, 0, 0))
    offset.paste(shadow_img, (0, 18))
    out = Image.alpha_composite(out, offset)
    white = Image.new("RGBA", (BIG, BIG), (255, 255, 255, 255))
    white.putalpha(paw)
    return Image.alpha_composite(out, white)


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def main():
    art = draw()
    sizes = [256, 128, 64, 48, 32, 24, 16]
    assets = os.path.join(ROOT, "assets")
    os.makedirs(assets, exist_ok=True)
    ico = os.path.join(assets, "PuppyCompanion.ico")
    art.resize((256, 256), Image.LANCZOS).save(ico, format="ICO", sizes=[(s, s) for s in sizes])
    art.resize((512, 512), Image.LANCZOS).save(os.path.join(assets, "PuppyCompanion.png"))
    lines = ['"""Window icon PNGs, written by tools/make_icon.py."""', ""]
    for s in (64, 32):
        data = base64.b64encode(png_bytes(art.resize((s, s), Image.LANCZOS))).decode("ascii")
        lines.append("ICON_%d = (" % s)
        for i in range(0, len(data), 96):
            lines.append('    "%s"' % data[i:i + 96])
        lines.append(")")
        lines.append("")
    with open(os.path.join(ROOT, "puppy_companion", "icon_data.py"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print("wrote", ico)


if __name__ == "__main__":
    main()
