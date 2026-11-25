"""Puppy Admin's copies of Puppy Companion's Kingdom Hearts shapes (companion/puppy_companion/khart.py),
so both apps draw the same menu: written to assets/hud/ at 2x (used with SliceScale 0.5).

  slab_v1.png, slab_hover_v1.png - a KH menu entry: dark slab, light rim, round top-left corner (fixed colours)
  slab_sel_v1.png                - the chosen entry: deep red with the bright red outline (fixed colours)
  cardhead_v1.png                - a status card's name plate (dark, round top corners, fixed colours)
  box_fill_v1.png                - framed box body (white: tinted with the theme's surface)
  box_rim_v1.png                 - framed box rim + inner line (white: tinted with the theme's accent)
  button_v1.png                  - button body: shaded top to bottom like Puppy Admin's buttons, light gloss
                                   (light grey: tinted with the button's own colour)
  button_rim_v1.png              - the button's outline (white: tinted with the theme's border colour)

Each shape is drawn twice, on black and on white, and the alpha is recovered from the difference,
so the anti-aliased edges are real transparency. Run: python3 tools/make_kh_shapes.py
(bump the _v names when the art changes: the script caches images by URL).
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "companion"))
from puppy_companion import khart  # noqa: E402

OUT = os.path.join(ROOT, "assets", "hud")
K = 2.0
WHITE = (255, 255, 255)
SLAB_TOP, SLAB_BOT, SLAB_RIM = (58, 60, 72), (12, 12, 18), (150, 155, 175)


def to_png(draw, name):
    """draw(back) -> rows; writes an RGBA PNG with the alpha recovered from black / white backs."""
    on_black, on_white = draw((0, 0, 0)), draw(WHITE)
    h, w = len(on_black), len(on_black[0])
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            b, wt = on_black[y][x], on_white[y][x]
            a = 1 - (sum(wt) - sum(b)) / (3 * 255.0)
            a = max(0.0, min(1.0, a))
            c = tuple(khart.clamp8(b[i] / a) if a > 0.004 else 0 for i in range(3))
            px[x, y] = c + (khart.clamp8(a * 255),)
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    print("wrote", path, img.size)


def main():
    to_png(lambda back: khart.menu_item(back, K), "slab_v1.png")
    to_png(lambda back: khart.menu_item(back, K, "hover"), "slab_hover_v1.png")
    to_png(lambda back: khart.menu_item(back, K, "selected"), "slab_sel_v1.png")
    to_png(lambda back: khart.shape(round(60 * K), round(36 * K), 10 * K, khart.mix(SLAB_TOP, WHITE, 0.06), SLAB_BOT,
                                    SLAB_RIM, K, back, corners="top", gloss=0.05), "cardhead_v1.png")
    s = round(48 * K)
    to_png(lambda back: khart.shape(s, s, 11 * K, WHITE, WHITE, WHITE, 0, back), "box_fill_v1.png")
    # rim only: the body is drawn in the background colour, so it comes out transparent
    to_png(lambda back: khart.panel(back, WHITE, back, K), "box_rim_v1.png")
    body = (232, 232, 232)
    bw, bh = round(44 * K), round(30 * K)
    to_png(lambda back: khart.shape(bw, bh, 7 * K, body, khart.multiply(body, khart.BUTTON_SHADE), body, 0, back, gloss=0.14),
           "button_v1.png")
    to_png(lambda back: khart.shape(bw, bh, 7 * K, back, back, WHITE, 1.5 * K, back), "button_rim_v1.png")


if __name__ == "__main__":
    main()
