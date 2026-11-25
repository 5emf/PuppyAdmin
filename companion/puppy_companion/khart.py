"""The Kingdom Hearts UI style's shapes for the companion, matching Puppy Admin's KHStyle:
buttons shaded from their colour at the top to a deeper blue-tinted shade at the bottom
(Puppy Admin's UIGradient 160,175,225), the hovered button deep red with a bright red rounded
outline, red selected tabs, framed panels with an accent rim, a glossy accent capsule behind
the title with an orange line under it, and a bobbing glove pointing at the hovered button.

Every shape is computed here as rows of colours (no image files, so it follows every theme
colour); `photo` turns rows into a Tk PhotoImage. Pure functions except `photo` / `fill_photo`.
"""
import math

# Puppy Admin's KHStyle constants (PuppyAdmin.lua, UIAPI.KHStyle)
UNDERLINE = (255, 140, 40)
SELECT = (150, 18, 28)
SELECT_EDGE = (255, 60, 60)
BUTTON_SHADE = (160, 175, 225)   # multiplied into the bottom of buttons
PANEL_SHADE = (95, 120, 190)     # and of window-sized panels
WHITE = (255, 255, 255)


def clamp8(n):
    return max(0, min(255, int(round(n))))


def hex_rgb(h):
    h = str(h).lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def to_hex(c):
    return "#%02x%02x%02x" % tuple(clamp8(v) for v in c)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def multiply(c, shade):
    return tuple(c[i] * shade[i] / 255.0 for i in range(3))


def _coverage(d):
    """Pixel coverage from a signed distance (negative inside), 1 px of anti-aliasing."""
    return max(0.0, min(1.0, 0.5 - d))


def _sdf(px, py, w, h, radii):
    """Signed distance from (px, py) to a w x h box with per-corner radii (tl, tr, br, bl)."""
    left, top = px < w / 2, py < h / 2
    r = radii[0] if (left and top) else radii[1] if top else radii[3] if left else radii[2]
    qx = abs(px - w / 2) - (w / 2 - r)
    qy = abs(py - h / 2) - (h / 2 - r)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    return outside + min(max(qx, qy), 0.0) - r


def shape(w, h, radius, top, bottom, edge, edge_w, back, corners="all", gloss=0.0):
    """Rows (h lists of w RGB tuples) of a rounded rectangle on `back`: fill shaded from
    `top` to `bottom`, an `edge`-coloured outline `edge_w` px wide, an optional glossy
    highlight over the top part. corners: "all" or "top" (square bottom, for tabs)."""
    w, h = max(2, int(w)), max(2, int(h))
    r = max(0.0, min(float(radius), w / 2.0, h / 2.0))
    radii = (r, r, r, r) if corners == "all" else (r, r, 0.0, 0.0)
    rows = []
    for y in range(h):
        t = y / (h - 1)
        fill = mix(top, bottom, t)
        if gloss > 0 and t < 0.48:
            fill = mix(fill, WHITE, gloss * (1 - t / 0.48))
        row = []
        for x in range(w):
            d = _sdf(x + 0.5, y + 0.5, w, h, radii)
            outer = _coverage(d)
            inner = _coverage(d + edge_w) if edge_w > 0 else outer
            c = tuple(back[i] * (1 - outer) + edge[i] * (outer - inner) + fill[i] * inner for i in range(3))
            row.append(c)
        rows.append(row)
    return rows


# ------------------------------------------------------------------ the style's pieces
def button(base, line, back, k=1.0, state="normal"):
    """A button face; state: normal, hover (deep red + bright red outline), pressed, disabled."""
    w, h, r = round(44 * k), round(30 * k), 7 * k
    if state == "hover":
        return shape(w, h, r, SELECT, multiply(SELECT, BUTTON_SHADE), SELECT_EDGE, max(2.0, 2 * k), back)
    if state == "pressed":
        dark = mix(SELECT, (0, 0, 0), 0.35)
        return shape(w, h, r, dark, multiply(dark, BUTTON_SHADE), SELECT_EDGE, max(2.0, 2 * k), back)
    if state == "disabled":
        return shape(w, h, r, base, base, line, max(1.0, k), back)
    return shape(w, h, r, base, multiply(base, BUTTON_SHADE), line, max(1.0, k), back, gloss=0.12)


def tab(base, line, back, k=1.0, state="normal"):
    """A notebook tab (rounded top); selected = red like Puppy Admin's selected menu tabs."""
    w, h, r = round(44 * k), round(30 * k), 8 * k
    if state == "selected":
        return shape(w, h, r, SELECT, multiply(SELECT, BUTTON_SHADE), SELECT_EDGE, max(2.0, 2 * k), back, corners="top")
    if state == "hover":
        lit = mix(base, WHITE, 0.08)
        return shape(w, h, r, lit, multiply(lit, BUTTON_SHADE), line, max(1.0, k), back, corners="top", gloss=0.1)
    return shape(w, h, r, base, multiply(base, BUTTON_SHADE), line, max(1.0, k), back, corners="top", gloss=0.08)


def panel(fill, rim, back, k=1.0):
    """A framed panel: flat fill (children paint the same colour), accent rim, a thin
    lighter inner line. Square-ish so it 9-slices with border `panel_border(k)`."""
    s = round(48 * k)
    r = 11 * k
    rim_w = max(2.0, 2 * k)
    outer = shape(s, s, r, fill, fill, rim, rim_w, back)
    inner_line = mix(rim, WHITE, 0.45)
    inset = rim_w + max(2.0, 2 * k)
    for y in range(s):
        for x in range(s):
            d = _sdf(x + 0.5, y + 0.5, s, s, (r,) * 4) + inset
            a = _coverage(d) - _coverage(d + 1.0)
            if a > 0:
                outer[y][x] = mix(outer[y][x], inner_line, a * 0.55)
    return outer


def panel_border(k=1.0):
    return int(round(16 * k))


def button_border(k=1.0):
    return int(round(9 * k))


def capsule(width, accent, back, k=1.0):
    """The glossy title capsule (Puppy Admin's pill_v1 tinted with the accent)."""
    h = round(34 * k)
    top = mix(accent, WHITE, 0.55)
    bottom = mix(accent, (0, 0, 0), 0.25)
    return shape(round(width), h, h / 2, top, bottom, mix(accent, WHITE, 0.35), max(1.0, k), back, gloss=0.35)


def underline(width, back, k=1.0):
    """The orange line under titles, fading out to the right."""
    w, h = max(2, round(width)), max(2, round(4 * k))
    rows = []
    for y in range(h):
        edge = 1 - abs((y + 0.5) / h - 0.5) * 2  # soft top / bottom
        row = []
        for x in range(w):
            fade = 1 - max(0.0, (x / (w - 1) - 0.55) / 0.45)
            row.append(mix(back, UNDERLINE, max(0.0, min(1.0, edge * 1.6)) * fade))
        rows.append(row)
    return rows


# ------------------------------------------------------------------ Tk glue
def rows_data(rows):
    """PhotoImage.put data for rows."""
    return " ".join("{" + " ".join(to_hex(c) for c in row) + "}" for row in rows)


def fill_photo(img, rows):
    """Redraws an existing PhotoImage in place (ttk elements keep pointing at it)."""
    h, w = len(rows), len(rows[0])
    img.blank()
    img.configure(width=w, height=h)
    img.put(rows_data(rows), to=(0, 0))
    return img


def photo(master, rows):
    import tkinter as tk
    h, w = len(rows), len(rows[0])
    img = tk.PhotoImage(master=master, width=w, height=h)
    return fill_photo(img, rows)


def glove_size(k=1.0):
    """The closest glove size in kh_data.GLOVE for this screen scale."""
    from . import kh_data
    want = 28 * k
    return min(kh_data.GLOVE, key=lambda s: abs(s - want))


def bob(t, k=1.0):
    """The glove's left-right bob in pixels at time t (seconds)."""
    return round(math.sin(t * 6.0) * 3 * k)
