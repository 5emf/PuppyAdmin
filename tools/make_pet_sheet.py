"""Cuts the owner's original pet character sheet (assets/pet/cat_source.jpg: 7 columns x 5 rows of
pixel-art frames on a light background) into a transparent sprite sheet for the Pupdates pet.

Each frame: found from the gaps between drawings, the background removed by a flood fill from the
frame's edges (so the white muzzle and chest inside the dark outline stay), trimmed, and put in a
CELL x CELL cell with its feet on a common baseline. Writes:
  pupdates/android/app/src/main/assets/pet/cat_v1.png   (7 x 5 cells, same order as the source)
Run: python3 tools/make_pet_sheet.py
"""
import os
from collections import deque

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "pet", "cat_source.jpg")
OUT = os.path.join(ROOT, "pupdates", "android", "app", "src", "main", "assets", "pet", "cat_v1.png")
COLS, ROWS, CELL, PAD = 7, 5, 192, 6


def runs(a, minv):
    out, start = [], None
    for i, v in enumerate(a):
        if v >= minv and start is None:
            start = i
        if v < minv and start is not None:
            out.append((start, i - 1))
            start = None
    if start is not None:
        out.append((start, len(a) - 1))
    return out


def merge(rs, want):
    """Joins the closest runs until there are `want` (a frame's effects can float apart from it)."""
    rs = list(rs)
    while len(rs) > want:
        gaps = [rs[i + 1][0] - rs[i][1] for i in range(len(rs) - 1)]
        i = gaps.index(min(gaps))
        rs[i:i + 2] = [(rs[i][0], rs[i + 1][1])]
    return rs


def cut(img, bg, box):
    x0, y0, x1, y1 = box
    a = img[y0:y1 + 1, x0:x1 + 1].astype(int)
    h, w = a.shape[:2]
    near = np.abs(a - bg).sum(2) < 70
    seen = np.zeros((h, w), bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and near[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                q.append((ny, nx))
    rgba = np.dstack([a, np.where(seen, 0, 255)]).astype(np.uint8)
    out = Image.fromarray(rgba, "RGBA")
    bb = out.getbbox()
    return out.crop(bb) if bb else out


def main():
    src = Image.open(SRC).convert("RGB")
    img = np.asarray(src)
    bg = img[5, 5].astype(int)
    mask = np.abs(img.astype(int) - bg).sum(2) > 40
    row_runs = merge(runs(mask.sum(1), 2), ROWS)
    assert len(row_runs) == ROWS, row_runs
    frames = []
    for (y0, y1) in row_runs:
        col_runs = merge(runs(mask[y0:y1 + 1].sum(0), 1), COLS)
        assert len(col_runs) == COLS, col_runs
        frames.append([cut(img, bg, (x0, y0, x1, y1)) for (x0, x1) in col_runs])
    biggest = max(max(f.size) for row in frames for f in row)
    scale = (CELL - 2 * PAD) / biggest
    sheet = Image.new("RGBA", (COLS * CELL, ROWS * CELL), (0, 0, 0, 0))
    for r, row in enumerate(frames):
        for c, f in enumerate(row):
            f = f.resize((max(1, round(f.width * scale)), max(1, round(f.height * scale))), Image.NEAREST)
            x = c * CELL + (CELL - f.width) // 2
            y = r * CELL + CELL - PAD - f.height       # feet on the baseline
            sheet.alpha_composite(f, (x, y))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    sheet.save(OUT, optimize=True)
    print("wrote", OUT, sheet.size, "scale %.3f" % scale)


if __name__ == "__main__":
    main()
