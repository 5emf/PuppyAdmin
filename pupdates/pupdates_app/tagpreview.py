"""The tag preview: draws a tag the way Puppy Admin's Tags.build does in Roblox, with the pictures
actually loaded.

- Layout: the same numbers as Tags.build (padding 12 x 6 with a backdrop, 4 x 4 without; picture
  max(text height, size x 1.5); 8 px gap; text lines size x 1.35 tall; the line under it size - 8,
  at least 12; backdrop corner min(14, height / 2); picture round or 6 px corners), the same
  colours (the line under it mixed 40 % toward white, black text outlines at 70 % / 60 %), and
  rainbow as one hue for the whole text going round every 4 s (HSV(t / 4, 0.9, 1)).
- The far view: past 30 studs Puppy Admin shows only the picture (no backdrop or text).
- Pictures load like Puppy Admin's resolveImageSource: image links are downloaded (GitHub page
  links become raw links), Roblox ids / links / rbxassetid / rbxthumb go through Roblox's
  thumbnail service, "avatar" is the first wearer's head shot. A custom picture that does not load
  is left out of the layout, as in the game.
- Fonts: the files in pupdates/tagfonts (tools/make_tag_fonts.py): the real font where Roblox's is
  free, a close free stand-in for Gotham and SciFi.
Drawing needs Pillow; `available()` says whether it is there.
"""
import io
import json
import math
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request

from . import core, tags

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # the app falls back to a plain preview
    Image = ImageDraw = ImageFont = None

THUMB_ASSET = ("https://thumbnails.roblox.com/v1/assets?assetIds=%s&returnPolicy=PlaceHolder&size=420x420"
               "&format=Png&isCircular=false")
THUMB_HEAD = "https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=%s&size=150x150&format=Png&isCircular=false"
ASSET_INFO = "https://economy.roblox.com/v2/assets/%s/details"   # best effort: tells a Decal id from an Image id
MAX_IMAGE = 12 * 1024 * 1024
RAINBOW_PERIOD = 4.0
FAR_STUDS = 30


def available():
    return Image is not None


# ------------------------------------------------------------------ fonts
def font_dir():
    here = os.path.dirname(os.path.abspath(__file__))
    places = [os.path.join(getattr(sys, "_MEIPASS", ""), "tagfonts"), os.path.join(os.path.dirname(here), "tagfonts")]
    for d in places:
        if os.path.isfile(os.path.join(d, "fonts.json")):
            return d
    return None


_font_map = None


def font_map():
    global _font_map
    if _font_map is None:
        d = font_dir()
        try:
            with open(os.path.join(d, "fonts.json"), encoding="utf-8") as f:
                _font_map = json.load(f)
        except (OSError, ValueError, TypeError):
            _font_map = {}
    return _font_map


def font_entry(name):
    """(path or None, info) for a tag font; an unknown name is GothamBold, as Enum.Font fails over in Tags.build."""
    m = font_map()
    info = m.get(name) or m.get("GothamBold") or {}
    d = font_dir()
    path = os.path.join(d, info["file"]) if d and info.get("file") else None
    return (path if path and os.path.isfile(path) else None), info


_fonts = {}


def load_font(name, px):
    key = (name, int(round(px)))
    if key not in _fonts:
        path, _ = font_entry(name)
        try:
            _fonts[key] = ImageFont.truetype(path, max(1, key[1])) if path else ImageFont.load_default()
        except (OSError, ValueError):
            _fonts[key] = ImageFont.load_default()
    return _fonts[key]


# ------------------------------------------------------------------ picture sources
def resolve(raw):
    """Puppy Admin's resolveImageSource: (kind, value) with kind url / asset / headshot, or
    ("unsupported" | "bad", reason). None for an empty field."""
    s = (raw or "").strip()
    if not s:
        return None
    m = re.match(r"^https://github\.com/([^/]+)/([^/]+)/blob/(.+)$", s)
    if m:
        s = "https://raw.githubusercontent.com/%s/%s/%s" % m.groups()
    if s.startswith("rbxthumb"):
        kind = re.search(r"type=([A-Za-z]+)", s)
        ident = re.search(r"[?&/]id=(\d+)", s) or re.search(r"\bid=(\d+)", s)
        if kind and ident and kind.group(1) == "AvatarHeadShot":
            return ("headshot", ident.group(1))
        if kind and ident and kind.group(1) == "Asset":
            return ("asset", ident.group(1))
        return ("unsupported", "This Roblox thumbnail link shows in the game; the preview can only load head shots and assets")
    if s.startswith("rbxasset"):
        m = re.match(r"^rbxassetid://(\d+)", s)
        if m:
            return ("asset", m.group(1))
        return ("unsupported", "A file inside the Roblox app: it shows in the game, the preview cannot load it")
    if s.isdigit():
        return ("asset", s)
    if "roblox.com" in s:
        m = re.search(r"(\d+)", s)
        return ("asset", m.group(1)) if m else ("bad", "No asset id in that link")
    if re.match(r"^https?://", s):
        return ("url", s)
    return ("bad", "Not an image id, asset or image URL")


class Picture:
    def __init__(self, state="loading", image=None, note="", error=""):
        self.state, self.image, self.note, self.error = state, image, note, error   # loading / ok / failed


class Images:
    """Loads pictures in the background, once per source. post(fn) runs fn on the window's thread."""

    def __init__(self, post, opener=None, sleep=time.sleep):
        self.post, self.opener, self.sleep = post, opener, sleep
        self.cache = {}
        self.lock = threading.Lock()

    def get(self, source, on_ready):
        """A Picture for a resolve() result (loading at first; on_ready() runs once it is in)."""
        if source is None:
            return None
        kind, value = source
        if kind in ("unsupported", "bad"):
            return Picture("failed", error=value)
        with self.lock:
            pic = self.cache.get(source)
            if pic is None:
                pic = self.cache[source] = Picture()
                threading.Thread(target=self._load, args=(source, pic, on_ready), daemon=True).start()
            elif pic.state == "loading":
                pic.waiting = getattr(pic, "waiting", []) + [on_ready]
        return pic

    def _get(self, url, limit=MAX_IMAGE):
        opener = self.opener or urllib.request.urlopen
        req = urllib.request.Request(url, headers={"User-Agent": "Pupdates-TagPreview", "Accept": "*/*"})
        try:
            with opener(req, timeout=25) as r:
                data = r.read(limit + 1)
                ctype = (r.headers.get("Content-Type") if getattr(r, "headers", None) else "") or ""
        except urllib.error.HTTPError as e:
            raise RuntimeError("the server answered HTTP %d" % e.code)
        except (urllib.error.URLError, OSError) as e:
            raise RuntimeError("could not connect (%s)" % getattr(e, "reason", e))
        if len(data) > limit:
            raise RuntimeError("the picture is bigger than %d MB" % (limit // (1024 * 1024)))
        return data, ctype

    def _thumb(self, url, what):
        for attempt in range(4):
            data, _ = self._get(url, 256 * 1024)
            try:
                entry = (json.loads(data.decode("utf-8")).get("data") or [{}])[0]
            except (ValueError, AttributeError, IndexError):
                raise RuntimeError("Roblox's thumbnail service sent something unexpected")
            state = entry.get("state")
            if state == "Completed" and entry.get("imageUrl"):
                return entry["imageUrl"]
            if state == "Pending" and attempt < 3:
                self.sleep(1.5)
                continue
            if state == "Blocked":
                raise RuntimeError("Roblox has blocked %s (moderated or private)" % what)
            raise RuntimeError("Roblox has no picture for %s (%s)" % (what, state or "no answer"))
        raise RuntimeError("Roblox is still making the picture for %s: try again in a moment" % what)

    def _load(self, source, pic, on_ready):
        kind, value = source
        note = ""
        try:
            if kind == "url":
                data, ctype = self._get(value)
            elif kind == "headshot":
                data, ctype = self._get(self._thumb(THUMB_HEAD % value, "user %s" % value))
            else:
                data, ctype = self._get(self._thumb(THUMB_ASSET % value, "asset %s" % value))
                note = self._asset_note(value)
            fmt = core.image_kind(data)
            if not fmt:
                looks = "a web page" if b"<html" in data[:2048].lower() else (ctype or "something else")
                raise RuntimeError("that link is not a picture (it sent %s)" % looks)
            img = Image.open(io.BytesIO(data))
            img.load()
            img = img.convert("RGBA")
            if kind == "url" and fmt[1] in ("webp", "gif"):
                note = (note + " " if note else "") + "%s from a link: Roblox may not show this format (PNG or JPG is safe)." % fmt[1].upper()
            result = Picture("ok", img, note=note)
        except Exception as e:  # shown under the preview
            result = Picture("failed", error=str(e))
        with self.lock:
            pic.state, pic.image, pic.note, pic.error = result.state, result.image, result.note, result.error
            waiting = [on_ready] + getattr(pic, "waiting", [])
        for fn in waiting:
            self.post(fn)

    def _asset_note(self, asset_id):
        try:
            data, _ = self._get(ASSET_INFO % asset_id, 256 * 1024)
            type_id = json.loads(data.decode("utf-8")).get("AssetTypeId")
        except Exception:
            return ""
        if type_id == 13:
            return ("Asset %s is a Decal: a script that sets a Decal id often shows nothing in the game; "
                    "use the Image id behind it (open the decal in Studio to see it)." % asset_id)
        return ""


# ------------------------------------------------------------------ layout (Tags.build)
def layout(d, measure, has_picture):
    """The tag's boxes in Roblox pixels. measure(text, font, px) -> width. Mirrors Tags.build."""
    size = max(8.0, min(48.0, float(d.get("size", 22))))
    sub_size = max(12.0, size - 8)
    text, sub = str(d.get("text") or ""), str(d.get("sub") or "")
    font = d.get("font") or "GothamBold"
    bd = d["backdrop"]
    line_main = math.ceil(size * 1.35)
    line_sub = math.ceil(sub_size * 1.35) if sub else 0
    text_h = line_main + line_sub
    width = lambda s, px: measure(s, font, px) if s else 0
    text_w = math.ceil(max(width(text, size), width(sub, sub_size))) + 10
    pic = math.floor(max(text_h, size * 1.5)) if has_picture else 0
    gap = 8 if has_picture and text_w > 0 else 0
    pad_x, pad_y = (12, 6) if bd["on"] else (4, 4)
    card_w = math.ceil(pad_x * 2 + pic + gap + text_w)
    card_h = math.ceil(pad_y * 2 + max(text_h, pic))
    area = (pad_x + pic + gap, pad_y, card_w - (pad_x * 2 + pic + gap), card_h - pad_y * 2)
    split = line_main / text_h if sub else 1.0
    return {
        "size": size, "sub_size": sub_size, "card": (card_w, card_h), "pic": pic,
        "pic_box": (pad_x, math.floor((card_h - pic) / 2), pic, pic),
        "main_box": (area[0], area[1], area[2], area[3] * split),
        "sub_box": (area[0], area[1] + area[3] * split, area[2], area[3] * (1 - split)),
        "align": "left" if has_picture else "center",
        "corner": min(14, card_h / 2) if bd["on"] and bd["round"] else 0,
        "far": (pic + 8, pic + 8) if has_picture else None,
    }


def hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return (round(r * 255), round(g * 255), round(b * 255))


def text_colours(d, t):
    """(main, sub) colours: the line under the text is the main colour mixed 40 % toward white."""
    main = hsv((t / RAINBOW_PERIOD) % 1, 0.9, 1) if d.get("rainbow") else tuple(int(c) for c in d["color"])
    return main, tuple(round(c + (255 - c) * 0.4) for c in main)


# ------------------------------------------------------------------ drawing
def _rounded_mask(w, h, r):
    m = Image.new("L", (max(1, w), max(1, h)), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=max(0, r), fill=255)
    return m


_covers = {}


def _cover(img, w, h):
    """ScaleType.Crop: fill w x h, keep the aspect, cut the overflow evenly (cached: the rainbow redraws often)."""
    w, h = max(1, int(round(w))), max(1, int(round(h)))
    key = (id(img), w, h)
    hit = _covers.get(key)
    if hit is not None and hit[0] is img:
        return hit[1].copy()
    k = max(w / img.width, h / img.height)
    big = img.resize((max(1, math.ceil(img.width * k)), max(1, math.ceil(img.height * k))), Image.LANCZOS)
    x, y = (big.width - w) // 2, (big.height - h) // 2
    out = big.crop((x, y, x + w, y + h))
    if len(_covers) > 32:
        _covers.clear()
    _covers[key] = (img, out)
    return out.copy()


def _stand_in_head(px):
    """A neutral head and shoulders where an avatar would be (no wearer yet / the default tag)."""
    img = Image.new("RGBA", (px, px), (196, 201, 210, 255))
    d = ImageDraw.Draw(img)
    d.ellipse([px * 0.3, px * 0.16, px * 0.7, px * 0.56], fill=(238, 240, 244, 255))
    d.ellipse([px * 0.12, px * 0.6, px * 0.88, px * 1.3], fill=(238, 240, 244, 255))
    return img


def _text(layer, box, text, font, colour, stroke_alpha, align, scale):
    if not text:
        return
    x, y, w, h = [v * scale for v in box]
    tl = ImageDraw.Draw(layer)
    sw = max(1, int(round(scale)))
    if align == "left":
        anchor, ax = "lm", x
    else:
        anchor, ax = "mm", x + w / 2
    tl.text((ax, y + h / 2), text, font=font, fill=colour + (255,), anchor=anchor, stroke_width=sw,
            stroke_fill=(0, 0, 0, round(255 * stroke_alpha)))


def draw_tag(d, lay, picture_img, backdrop_img, t, scale):
    """The tag card as an RGBA image (scale = screen pixels per Roblox pixel)."""
    cw, ch = lay["card"]
    W, H = max(1, math.ceil(cw * scale)), max(1, math.ceil(ch * scale))
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd, pf = d["backdrop"], d["pfp"]
    r = lay["corner"] * scale
    if bd["on"]:
        fill = Image.new("RGBA", (W, H), tuple(bd["color"]) + (round(255 * (1 - float(bd["transparency"]))),))
        mask = _rounded_mask(W, H, r) if r else Image.new("L", (W, H), 255)
        bg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        bg.paste(fill, (0, 0), mask)
        out.alpha_composite(bg)
        if backdrop_img is not None:
            pic = _cover(backdrop_img, W, H)
            a = pic.getchannel("A").point(lambda v: round(v * (1 - float(bd["imageTransparency"]))))
            pic.putalpha(Image.composite(a, Image.new("L", (W, H), 0), mask))
            out.alpha_composite(pic)
    if lay["pic"]:
        x, y, w, h = [v * scale for v in lay["pic_box"]]
        side = max(1, int(round(w)))
        src = picture_img if picture_img is not None else _stand_in_head(side)
        pic = _cover(src, side, side)
        radius = side / 2 if pf["round"] else 6 * scale
        pic.putalpha(Image.composite(pic.getchannel("A"), Image.new("L", (side, side), 0), _rounded_mask(side, side, radius)))
        out.alpha_composite(pic, (int(round(x)), int(round(y))))
    main_c, sub_c = text_colours(d, t)
    font = d.get("font") or "GothamBold"
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    _text(layer, lay["main_box"], d.get("text") or "", load_font(font, lay["size"] * scale), main_c, 0.7, lay["align"], scale)
    _text(layer, lay["sub_box"], d.get("sub") or "", load_font(font, lay["sub_size"] * scale), sub_c, 0.6, lay["align"], scale)
    out.alpha_composite(layer)
    return out


def draw_far(d, lay, picture_img, scale):
    """Past 30 studs: only the picture, 4 px in from its box."""
    if not lay["far"]:
        return None
    side = max(1, int(round(lay["pic"] * scale)))
    box = max(1, int(round(lay["far"][0] * scale)))
    out = Image.new("RGBA", (box, box), (0, 0, 0, 0))
    src = picture_img if picture_img is not None else _stand_in_head(side)
    pic = _cover(src, side, side)
    radius = side / 2 if d["pfp"]["round"] else 6 * scale
    pic.putalpha(Image.composite(pic.getchannel("A"), Image.new("L", (side, side), 0), _rounded_mask(side, side, radius)))
    off = int(round(4 * scale))
    out.alpha_composite(pic, (off, off))
    return out


def measure_with_pillow(text, font, px):
    return load_font(font, px).getlength(text)


def scene(d, picture_img, backdrop_img, has_picture, t, width, scale=1.0, label_scale=1.0):
    """The whole preview: a sky, the tag close up and, beside it, how it looks far away.
    Returns (image, shown scale)."""
    lay = layout(d, measure_with_pillow, has_picture)
    cw, ch = lay["card"]
    room = width * 0.66
    shown = min(scale, room / max(1.0, cw))
    tag = draw_tag(d, lay, picture_img, backdrop_img, t, shown)
    far = draw_far(d, lay, picture_img, shown)
    label = load_font("Gotham", 11 * label_scale)
    height = max(int(tag.height + 34 * label_scale), int(72 * label_scale))
    top, bottom = (112, 166, 226), (196, 224, 250)          # a daytime sky
    column = Image.new("RGBA", (1, height))
    for yy in range(height):
        k = yy / max(1, height - 1)
        column.putpixel((0, yy), tuple(round(top[i] + (bottom[i] - top[i]) * k) for i in range(3)) + (255,))
    img = column.resize((int(width), height))
    cx = int(width * 0.36)
    ty = int((height - tag.height) / 2 + 6 * label_scale)
    img.alpha_composite(tag, (max(0, cx - tag.width // 2), max(0, ty)))
    dr = ImageDraw.Draw(img)
    ink = (28, 52, 92, 255)
    dr.text((8 * label_scale, 6 * label_scale), "close up" + ("" if shown >= scale - 1e-6 else "  (%d%% size)" % round(100 * shown / scale)),
            font=label, fill=ink)
    fx = int(width * 0.8)
    dr.text((fx, 6 * label_scale), "past %d studs" % FAR_STUDS, font=label, fill=ink, anchor="ma")
    if far is not None:
        img.alpha_composite(far, (fx - far.width // 2, max(0, int((height - far.height) / 2 + 6 * label_scale))))
    else:
        dr.text((fx, height / 2), "(nothing shown)", font=label, fill=ink, anchor="mm")
    return img, shown


def png_bytes(img):
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "PNG")
    return buf.getvalue()


# ------------------------------------------------------------------ what to load + notes
def plan(d, first_wearer=None, wearer_name=None):
    """Which pictures the tag needs: {"picture": source or None, "backdrop": source or None} and notes."""
    pf, bd = d["pfp"], d["backdrop"]
    notes = []
    picture = None
    if pf["mode"] == "avatar":
        if first_wearer:
            picture = ("headshot", str(first_wearer))
            notes.append("Picture: %s's avatar (each wearer sees their own)." % (wearer_name or "the first wearer"))
        else:
            notes.append("Picture: each player's own avatar (no wearer here, so a stand-in head).")
    elif pf["mode"] == "custom":
        picture = resolve(pf["image"])
        if picture is None:
            notes.append("Picture: custom, but no image is set, so the game shows no picture.")
    backdrop = None
    if (bd.get("image") or "").strip():
        if bd["on"]:
            backdrop = resolve(bd["image"])
        else:
            notes.append("Backdrop image: not shown while the backdrop is off.")
    _, info = font_entry(d.get("font") or "GothamBold")
    if info.get("standin"):
        notes.append("Font: %s is a free stand-in for Roblox's %s (close, not identical)." % (info["file"].rsplit(".", 1)[0], info["roblox"]))
    return {"picture": picture, "backdrop": backdrop}, notes
