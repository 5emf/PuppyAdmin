"""Writes puppy_companion/cursors/*.cur from Puppy Admin's cursor images (assets/cursors).

Each .cur holds 32, 48 and 64 px 32-bit images (bitmap entries, readable by every Windows) with the hotspot at the same point as
Puppy Admin's Cursor.BUILTIN (fingertip, centre, blade tip). Needs Pillow (dev only).
"""
import os
import struct

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(REPO, "assets", "cursors")
OUT = os.path.join(os.path.dirname(HERE), "puppy_companion", "cursors")
CURSORS = {  # name: (source, hotspot as a fraction of the image)
    "glove": ("glove_v1.png", (0.992, 0.391)),
    "light": ("light_v1.png", (0.5, 0.5)),
    "keyblade": ("keyblade_v1.png", (0.836, 0.008)),
}
SIZES = (32, 48, 64)


def dib(img):
    """32-bit BGRA bitmap as stored in .ico/.cur: header with double height, bottom-up
    pixels, then an all-clear 1-bit AND mask (the alpha channel does the masking)."""
    w, h = img.size
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    px = img.load()
    rows = []
    for y in range(h - 1, -1, -1):
        rows.append(b"".join(struct.pack("BBBB", px[x, y][2], px[x, y][1], px[x, y][0], px[x, y][3]) for x in range(w)))
    mask_row = ((w + 31) // 32) * 4
    return header + b"".join(rows) + b"\x00" * (mask_row * h)


def write_cur(path, img, hot):
    entries, blobs = [], []
    for s in SIZES:
        blobs.append(dib(img.resize((s, s), Image.LANCZOS)))
        hx, hy = min(s - 1, round(hot[0] * s)), min(s - 1, round(hot[1] * s))
        entries.append((s, hx, hy))
    offset = 6 + 16 * len(SIZES)
    data = struct.pack("<HHH", 0, 2, len(SIZES))
    for (s, hx, hy), blob in zip(entries, blobs):
        data += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, hx, hy, len(blob), offset)
        offset += len(blob)
    with open(path, "wb") as f:
        f.write(data + b"".join(blobs))


os.makedirs(OUT, exist_ok=True)
for name, (src, hot) in CURSORS.items():
    img = Image.open(os.path.join(SRC, src)).convert("RGBA")
    write_cur(os.path.join(OUT, name + ".cur"), img, hot)
    print("wrote", name + ".cur")
