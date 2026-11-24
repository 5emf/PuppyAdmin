"""Keeps login cookies out of the log, whatever text an error carries."""
import re

_COOKIE = re.compile(r"_\|WARNING:-DO-NOT-SHARE-THIS\.[^\s\"';,]*")
_LONG_HEX = re.compile(r"[A-Fa-f0-9]{80,}")


def redact(text):
    text = _COOKIE.sub("[login cookie hidden]", str(text))
    return _LONG_HEX.sub("[hidden]", text)
