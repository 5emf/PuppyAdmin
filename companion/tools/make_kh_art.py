"""Writes companion/puppy_companion/kh_data.py: the Kingdom Hearts style's pointing glove
for the companion, from Puppy Admin's owner-supplied cursor image (assets/cursors/glove_v1.png),
mirrored so it points right (at the button it sits beside) and saved as small PNGs.

Run from the repository root:  python companion/tools/make_kh_art.py
"""
import base64
import io
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROOT, "assets", "cursors", "glove_v1.png")
OUT = os.path.join(ROOT, "companion", "puppy_companion", "kh_data.py")
SIZES = (22, 28, 36, 44, 56)


def main():
    img = Image.open(SRC).convert("RGBA").transpose(Image.FLIP_LEFT_RIGHT)
    img = img.crop(img.getbbox())
    lines = ['"""The Kingdom Hearts style pointer glove (PNG, base64), made by tools/make_kh_art.py',
             'from assets/cursors/glove_v1.png, mirrored to point right. Sizes in pixels -> data."""', "",
             "GLOVE = {"]
    for s in SIZES:
        w = s
        h = max(1, round(img.height * s / img.width))
        small = img.resize((w, h), Image.LANCZOS)
        buf = io.BytesIO()
        small.save(buf, "PNG", optimize=True)
        data = base64.b64encode(buf.getvalue()).decode("ascii")
        lines.append("    %d: (" % s)
        for i in range(0, len(data), 96):
            lines.append('        "%s"' % data[i:i + 96])
        lines.append("    ),")
    lines.append("}")
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote", OUT)


if __name__ == "__main__":
    main()
