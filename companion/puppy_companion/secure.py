"""Login cookies are encrypted with Windows DPAPI for the current Windows user.

Only the same Windows account on the same PC can decrypt them: a copy of
accounts.json taken to another PC, or read by another Windows user, gives
nothing usable.
"""
import sys

ENTROPY = b"PuppyCompanion/accounts/v1"
CRYPTPROTECT_UI_FORBIDDEN = 0x1


class ProtectorError(Exception):
    pass


class DpapiProtector:
    name = "Windows DPAPI (current user)"

    def __init__(self):
        if sys.platform != "win32":
            raise ProtectorError("Puppy Companion stores logins with Windows' own encryption, so it runs on Windows only.")
        import ctypes
        from ctypes import wintypes

        class DATA_BLOB(ctypes.Structure):
            _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

        self._ct = ctypes
        self._BLOB = DATA_BLOB
        crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._protect = crypt32.CryptProtectData
        self._protect.argtypes = [ctypes.POINTER(DATA_BLOB), wintypes.LPCWSTR, ctypes.POINTER(DATA_BLOB),
                                  ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DATA_BLOB)]
        self._protect.restype = wintypes.BOOL
        self._unprotect = crypt32.CryptUnprotectData
        self._unprotect.argtypes = [ctypes.POINTER(DATA_BLOB), ctypes.c_void_p, ctypes.POINTER(DATA_BLOB),
                                    ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(DATA_BLOB)]
        self._unprotect.restype = wintypes.BOOL
        self._free = kernel32.LocalFree
        self._free.argtypes = [ctypes.c_void_p]
        self._free.restype = ctypes.c_void_p

    def _blob(self, data):
        ct = self._ct
        buf = ct.create_string_buffer(bytes(data), len(data))
        return self._BLOB(len(data), ct.cast(buf, ct.POINTER(ct.c_char))), buf

    def _run(self, encrypt, data):
        ct = self._ct
        # the buffers must outlive the call: keep references to them
        src, _src_buf = self._blob(data)
        ent, _ent_buf = self._blob(ENTROPY)
        out = self._BLOB()
        if encrypt:
            ok = self._protect(ct.byref(src), "PuppyCompanion", ct.byref(ent), None, None,
                               CRYPTPROTECT_UI_FORBIDDEN, ct.byref(out))
        else:
            ok = self._unprotect(ct.byref(src), None, ct.byref(ent), None, None,
                                 CRYPTPROTECT_UI_FORBIDDEN, ct.byref(out))
        if not ok:
            err = ct.get_last_error()
            raise ProtectorError("Windows could not %s the saved login (error %d)%s" % (
                "encrypt" if encrypt else "decrypt", err,
                "" if encrypt else ": it was saved by another Windows user or PC, add the account again"))
        try:
            return ct.string_at(out.pbData, out.cbData)
        finally:
            self._free(ct.cast(out.pbData, ct.c_void_p))

    def protect(self, data):
        return self._run(True, data)

    def unprotect(self, data):
        return self._run(False, data)


def default_protector():
    return DpapiProtector()
