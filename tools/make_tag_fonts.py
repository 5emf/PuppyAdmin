"""Fonts for the Pupdates tag preview: free (SIL Open Font License) fonts for each of Puppy Admin's
tag fonts (TAG_FONTS), so the preview draws the text the way Roblox does.

Roblox's own files are not used. Where Roblox's font is itself a free font (Code = Inconsolata,
Arcade = Press Start 2P, SourceSansBold = Source Sans, FredokaOne = Fredoka One, Bangers,
Fantasy = Balthazar) the same font is used; Gotham (Roblox ships the commercial Gotham SSm) and
SciFi (Zekton, not free) get the closest free look-alike (Montserrat, Orbitron), marked
"standin" in fonts.json. Variable fonts are cut into the needed static weight with fontTools.

Writes pupdates/tagfonts/: the .ttf files, fonts.json (tag font -> file), LICENSES/<family>.txt.
Run: python3 tools/make_tag_fonts.py   (needs network + fontTools)
"""
import io
import json
import os
import urllib.request

from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "pupdates", "tagfonts")
BASE = "https://raw.githubusercontent.com/google/fonts/main/ofl/"

# tag font -> (google/fonts folder, file, axes or None, output name, Roblox's own font, stand-in?)
FONTS = {
    "GothamBold": ("montserrat", "Montserrat%5Bwght%5D.ttf", {"wght": 700}, "Montserrat-Bold.ttf", "Gotham SSm Bold", True),
    "Gotham": ("montserrat", "Montserrat%5Bwght%5D.ttf", {"wght": 400}, "Montserrat-Regular.ttf", "Gotham SSm", True),
    "GothamSemibold": ("montserrat", "Montserrat%5Bwght%5D.ttf", {"wght": 600}, "Montserrat-SemiBold.ttf", "Gotham SSm Semibold", True),
    "Code": ("inconsolata", "Inconsolata%5Bwdth,wght%5D.ttf", {"wght": 400, "wdth": 100}, "Inconsolata-Regular.ttf", "Inconsolata", False),
    "Arcade": ("pressstart2p", "PressStart2P-Regular.ttf", None, "PressStart2P-Regular.ttf", "Press Start 2P", False),
    "SourceSansBold": ("sourcesans3", "SourceSans3%5Bwght%5D.ttf", {"wght": 700}, "SourceSans3-Bold.ttf", "Source Sans Pro Bold", False),
    "FredokaOne": ("fredoka", "Fredoka%5Bwdth,wght%5D.ttf", {"wght": 600, "wdth": 100}, "Fredoka-SemiBold.ttf", "Fredoka One", False),
    "Bangers": ("bangers", "Bangers-Regular.ttf", None, "Bangers-Regular.ttf", "Bangers", False),
    "SciFi": ("orbitron", "Orbitron%5Bwght%5D.ttf", {"wght": 400}, "Orbitron-Regular.ttf", "Zekton", True),
    "Fantasy": ("balthazar", "Balthazar-Regular.ttf", None, "Balthazar-Regular.ttf", "Balthazar", False),
}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Pupdates-font-tool"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def main():
    os.makedirs(os.path.join(OUT, "LICENSES"), exist_ok=True)
    cache, mapping = {}, {}
    for tag_font, (folder, name, axes, out_name, roblox, standin) in FONTS.items():
        url = BASE + folder + "/" + name
        if url not in cache:
            cache[url] = get(url)
        font = TTFont(io.BytesIO(cache[url]))
        if axes:
            font = instancer.instantiateVariableFont(font, axes)
        font.save(os.path.join(OUT, out_name))
        lic = os.path.join(OUT, "LICENSES", folder + ".txt")
        if not os.path.exists(lic):
            with open(lic, "wb") as f:
                f.write(get(BASE + folder + "/OFL.txt"))
        mapping[tag_font] = {"file": out_name, "roblox": roblox, "standin": standin, "license": "LICENSES/" + folder + ".txt"}
        print("%-15s -> %s%s" % (tag_font, out_name, "  (stand-in for %s)" % roblox if standin else ""))
    with open(os.path.join(OUT, "fonts.json"), "w", encoding="utf-8") as f:
        json.dump(mapping, f, indent=2)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
