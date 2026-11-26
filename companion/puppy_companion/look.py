"""Look settings shared with Puppy Admin: theme presets and colour roles, text size,
mouse cursor and a background picture. Pure functions here; app.py applies them.

The roles and presets are the same as Puppy Admin's Theme (bg, surface, accent,
text, dim, border, on), so a preset looks the same in the game and in the app.
"Companion" is the app's original look.
"""
import os
import re
import sys

ROLES = ("bg", "surface", "accent", "text", "dim", "border", "on")
LABELS = {"bg": "Background", "surface": "Surface", "accent": "Accent", "text": "Text",
          "dim": "Muted text", "border": "Border", "on": "Toggle on / good"}

PRESETS = [
    ("Companion", {"bg": (20, 21, 26), "surface": (28, 29, 36), "accent": (90, 169, 255), "text": (233, 233, 238),
                   "dim": (155, 156, 168), "border": (50, 51, 63), "on": (111, 220, 140)}),
    # the ones below are Puppy Admin's Theme presets, value for value
    ("Default", {"bg": (23, 23, 23), "surface": (30, 30, 30), "accent": (226, 226, 226), "text": (244, 244, 244),
                 "dim": (160, 160, 160), "border": (55, 55, 55), "on": (80, 210, 100)}),
    ("Midnight", {"bg": (14, 18, 32), "surface": (22, 28, 48), "accent": (110, 150, 255), "text": (230, 236, 255),
                  "dim": (140, 152, 190), "border": (48, 58, 92), "on": (90, 140, 255)}),
    ("Puppy", {"bg": (30, 18, 26), "surface": (44, 26, 38), "accent": (255, 130, 190), "text": (255, 236, 246),
               "dim": (210, 160, 190), "border": (92, 52, 78), "on": (255, 105, 180)}),
    ("Forest", {"bg": (16, 24, 18), "surface": (24, 36, 27), "accent": (120, 210, 140), "text": (232, 245, 234),
                "dim": (150, 180, 155), "border": (52, 78, 58), "on": (80, 200, 110)}),
    ("Crimson", {"bg": (24, 12, 14), "surface": (38, 18, 22), "accent": (235, 80, 90), "text": (250, 234, 236),
                 "dim": (190, 150, 155), "border": (86, 40, 46), "on": (230, 70, 80)}),
    ("Light", {"bg": (240, 240, 244), "surface": (226, 226, 232), "accent": (60, 110, 230), "text": (24, 24, 28),
               "dim": (100, 100, 110), "border": (190, 190, 200), "on": (60, 170, 90)}),
    ("Sword Art Online", {"bg": (232, 234, 238), "surface": (248, 248, 250), "accent": (245, 155, 40), "text": (62, 64, 72),
                          "dim": (128, 132, 142), "border": (194, 198, 206), "on": (110, 200, 80)}),
    ("Kingdom Hearts", {"bg": (6, 10, 40), "surface": (12, 24, 96), "accent": (60, 130, 255), "text": (255, 255, 255),
                        "dim": (170, 190, 240), "border": (40, 90, 240), "on": (255, 214, 92)}),
]
PRESET_NAMES = [n for n, _ in PRESETS]

# a few colour names (Puppy Admin also takes names); anything else: #hex or r,g,b
NAMES = {"white": (255, 255, 255), "black": (0, 0, 0), "red": (235, 64, 64), "green": (80, 200, 110),
         "blue": (70, 130, 240), "pink": (255, 130, 190), "purple": (160, 100, 240), "orange": (255, 150, 60),
         "yellow": (250, 220, 70), "cyan": (70, 210, 230), "grey": (128, 128, 128), "gray": (128, 128, 128)}

# cursors: label -> .cur file in puppy_companion/cursors (made from Puppy Admin's cursor images)
CURSOR_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cursors")
CURSORS = {"Glove": "glove.cur", "Light": "light.cur", "Keyblade": "keyblade.cur"}
CURSOR_CHOICES = ["Default"] + list(CURSORS) + ["Custom file"]


def clamp8(n):
    return max(0, min(255, int(round(n))))


def to_hex(rgb):
    return "#%02x%02x%02x" % tuple(clamp8(c) for c in rgb)


def parse_color(text):
    """'#ff88cc', 'ff88cc', '#f8c', '255,136,204', '255 136 204' or a name -> (r, g, b) or None."""
    t = str(text or "").strip().lower()
    if not t:
        return None
    if t in NAMES:
        return NAMES[t]
    m = re.fullmatch(r"#?([0-9a-f]{6}|[0-9a-f]{3})", t)
    if m:
        h = m.group(1)
        if len(h) == 3:
            h = "".join(ch * 2 for ch in h)
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    parts = re.split(r"[\s,]+", t)
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        vals = tuple(int(p) for p in parts)
        if all(0 <= v <= 255 for v in vals):
            return vals
    return None


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def luminance(rgb):
    return (0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2]) / 255


def roles_for(preset, overrides=None):
    """The seven role colours: a preset plus any per-role overrides (role -> '#hex')."""
    base = dict(dict(PRESETS)[preset] if preset in PRESET_NAMES else PRESETS[0][1])
    for role, value in (overrides or {}).items():
        rgb = parse_color(value)
        if role in ROLES and rgb:
            base[role] = rgb
    return base


def palette(roles):
    """App colours derived from the roles (same idea as Puppy Admin's derive: a raised
    surface steps away from the background, lighter on dark themes, darker on light)."""
    bg, surface, accent = roles["bg"], roles["surface"], roles["accent"]
    light = luminance(bg) > 0.5
    step = -12 if light else 10
    field = tuple(c + step for c in surface)
    hover = tuple(c + step * 2 for c in surface)
    return {
        "BG": to_hex(bg), "CARD": to_hex(surface), "FIELD": to_hex(field), "HOVER": to_hex(hover),
        "LINE": to_hex(roles["border"]), "FG": to_hex(roles["text"]), "DIM": to_hex(roles["dim"]),
        "ACCENT": to_hex(accent), "GOOD": to_hex(roles["on"]),
        "ACCENT_HI": to_hex(mix(accent, (255, 255, 255), 0.2)), "ACCENT_LO": to_hex(mix(accent, (0, 0, 0), 0.15)),
        "ON_ACCENT": "#0b0d12" if luminance(accent) > 0.5 else "#ffffff",
        "SELECT": to_hex(mix(bg, accent, 0.35)),
        "TAB_HOVER": to_hex(mix(surface, roles["text"], 0.05)),
    }


def text_scale(value):
    try:
        v = float(value)
    except (TypeError, ValueError):
        return 1.0
    if v != v:
        return 1.0
    return max(0.5, min(2.0, round(v * 20) / 20))


def cursor_spec(choice, custom_path=""):
    """Tk cursor option for a choice ('' = Tk's normal arrow). Windows only: Tk takes
    '@file.cur' there; elsewhere custom cursors are not used."""
    if sys.platform != "win32" or choice == "Default":
        return ""
    if choice == "Custom file":
        path = str(custom_path or "")
        if path.lower().endswith((".cur", ".ani")) and os.path.isfile(path):
            return "@" + path.replace("\\", "/")
        return ""
    name = CURSORS.get(choice)
    if not name:
        return ""
    path = os.path.join(CURSOR_DIR, name)
    return ("@" + path.replace("\\", "/")) if os.path.isfile(path) else ""


# one-click styles: theme preset, font and cursor together (Puppy Admin's UI style)
STYLES = {
    "Standard": {"preset": "Companion", "font": "Default", "cursor": "Default"},
    "Kingdom Hearts": {"preset": "Kingdom Hearts", "font": "KH Menu", "cursor": "Glove"},
    "Sword Art Online": {"preset": "Sword Art Online", "font": "SAO UI", "cursor": "Default"},
}

