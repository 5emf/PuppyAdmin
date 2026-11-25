"""The Kingdom Hearts style fonts shipped with the app (puppy_companion/fonts).

On Windows they are loaded for this program only (AddFontResourceExW with
FR_PRIVATE): nothing is installed and they vanish when the app closes. Elsewhere
a font is used only if the system already has it.
"""
import os
import sys

FONT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
FR_PRIVATE = 0x10
DEFAULT = "Default"

# label -> (family name inside the font files, files). Same set as Puppy Admin's UIFont.CUSTOM.
FONTS = {
    "KH Menu": ("KHMenu", ("KHMenu.ttf", "KHMenuBold.ttf", "KHMenuItalic.ttf", "KHMenuBoldItalic.ttf")),
    "KH Gummi": ("KHGummi", ("KHGummi.ttf",)),
    "KH Data": ("KHData", ("KHData.ttf",)),
    "KH Title": ("KHTitle", ("KHTitle.ttf",)),
    "Kingdom Hearts": ("Kingdom Hearts", ("KingdomHearts.ttf",)),
    "KH Scala (symbols)": ("KHScala", ("KHScala.ttf",)),
    "KH Scala Script (symbols)": ("KHScala KHScala", ("KHScalaScript.ttf",)),
    # Sword Art Online-style fan fonts supplied by the owner (assets/fonts/SAO_FONTS_CREDIT.txt)
    "SAO UI": ("SAO UI TT", ("SAOUI.ttf", "SAOUIBold.ttf")),
    "SAO Welcome": ("SAO Welcome TT", ("SAOWelcome.ttf", "SAOWelcomeBold.ttf")),
}

_loaded = set()


def choices():
    return [DEFAULT] + list(FONTS)


def default_family():
    return "Segoe UI" if sys.platform == "win32" else "DejaVu Sans"


def load_private(files, adder=None):
    """Loads font files for this process only. Returns how many loaded (0 off Windows)."""
    if adder is None:
        if sys.platform != "win32":
            return 0
        import ctypes
        adder = ctypes.windll.gdi32.AddFontResourceExW
    n = 0
    for name in files:
        path = os.path.join(FONT_DIR, name)
        if path in _loaded:
            n += 1
            continue
        if not os.path.isfile(path):
            continue
        try:
            if adder(path, FR_PRIVATE, 0):
                _loaded.add(path)
                n += 1
        except OSError:
            pass
    return n


def family_for(label, available=None, adder=None):
    """Tk family name for a label (loading its files first), or the default family
    when the label is unknown or the font could not be made available."""
    entry = FONTS.get(label)
    if not entry:
        return default_family()
    family, files = entry
    load_private(files, adder)
    if callable(available):
        available = available()
    if available is not None and family not in available:
        return default_family()
    return family
