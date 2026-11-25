"""Writes companion/payload.json: the version and the checksum of every package file.

The auto-updater reads this from GitHub to decide whether a newer package is
available and to verify each file it downloads. Run it (and commit payload.json)
whenever you change puppy_companion and bump _payload.PAYLOAD_VERSION:

    python companion/tools/make_payload.py
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COMPANION = os.path.dirname(HERE)
PKG = os.path.join(COMPANION, "puppy_companion")
sys.path.insert(0, COMPANION)

from puppy_companion import _payload  # noqa: E402


def main():
    files = []
    for root, _dirs, names in os.walk(PKG):
        for name in sorted(names):
            if not name.endswith((".py", ".ttf", ".cur", ".wav")):
                continue
            full = os.path.join(root, name)
            rel = os.path.relpath(full, COMPANION).replace("\\", "/")
            with open(full, "rb") as f:
                data = f.read()
            files.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    files.sort(key=lambda e: e["path"])
    manifest = {"version": _payload.PAYLOAD_VERSION, "files": files}
    out = os.path.join(COMPANION, _payload.MANIFEST_NAME)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    print("wrote %s: version %s, %d files" % (out, manifest["version"], len(files)))


if __name__ == "__main__":
    main()
