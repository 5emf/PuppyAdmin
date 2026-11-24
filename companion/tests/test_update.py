"""Auto-update: check, download+verify, and the run_companion bootstrap loading it."""
import hashlib
import importlib
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
COMPANION = os.path.dirname(HERE)
sys.path.insert(0, COMPANION)

from puppy_companion import _payload  # noqa: E402


# a tiny package the fake "GitHub" serves as a newer version
NEW_INIT = 'from ._payload import PAYLOAD_VERSION as __version__\nSENTINEL = "updated-package"\n'
NEW_PAYLOAD = 'PAYLOAD_VERSION = "9.9.9"\n'


def _repo(files):
    """{rel_path: bytes} -> url->bytes map plus a valid manifest at the manifest url."""
    urls = {}
    entries = []
    for rel, data in files.items():
        urls[_payload.file_url(rel)] = data
        entries.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    manifest = {"version": "9.9.9", "files": sorted(entries, key=lambda e: e["path"])}
    urls[_payload.manifest_url()] = json.dumps(manifest).encode()
    return urls, manifest


class _Resp:
    def __init__(self, data):
        self._data, self.status = data, 200

    def read(self, n=-1):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def opener_for(urls, corrupt=None):
    def opener(request, timeout):
        url = request.full_url
        if url not in urls:
            raise urllib.error.HTTPError(url, 404, "Not Found", None, io.BytesIO(b""))
        data = urls[url]
        if corrupt and url == corrupt:
            data = data + b"# tampered\n"
        return _Resp(data)
    return opener


class UpdateTest(unittest.TestCase):
    @staticmethod
    def _purge():
        for m in [m for m in sys.modules if m == "puppy_companion" or m.startswith("puppy_companion.")]:
            del sys.modules[m]

    def _real_update(self):
        """Import the real package fresh (temp home in effect) and return its update module."""
        self._purge()
        import puppy_companion  # noqa: F401  (the real one at COMPANION)
        return importlib.import_module("puppy_companion.update")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._home = os.environ.get("PUPPY_COMPANION_HOME")
        os.environ["PUPPY_COMPANION_HOME"] = self.tmp
        self.update = self._real_update()
        self.files = {"puppy_companion/__init__.py": NEW_INIT.encode(),
                      "puppy_companion/_payload.py": NEW_PAYLOAD.encode()}

    def tearDown(self):
        if self._home is None:
            os.environ.pop("PUPPY_COMPANION_HOME", None)
        else:
            os.environ["PUPPY_COMPANION_HOME"] = self._home
        shutil.rmtree(self.tmp, ignore_errors=True)
        self._purge()  # drop any fake package so later test modules import the real one

    def test_check_reports_newer(self):
        urls, manifest = _repo(self.files)
        got = self.update.check(opener=opener_for(urls))
        self.assertEqual(got["version"], "9.9.9")

    def test_no_update_when_same_version(self):
        self.files["puppy_companion/_payload.py"] = ('PAYLOAD_VERSION = "%s"\n' % _payload.PAYLOAD_VERSION).encode()
        urls, manifest = _repo(self.files)
        manifest["version"] = _payload.PAYLOAD_VERSION
        urls[_payload.manifest_url()] = json.dumps(manifest).encode()
        self.assertIsNone(self.update.check(opener=opener_for(urls)))

    def test_download_verifies_and_activates(self):
        urls, _ = _repo(self.files)
        version = self.update.download(self.update.check(opener=opener_for(urls)), opener=opener_for(urls))
        self.assertEqual(version, "9.9.9")
        self.assertEqual(self.update.installed_version(), "9.9.9")
        pkg = os.path.join(self.update.code_root(), "9.9.9", "puppy_companion", "__init__.py")
        self.assertTrue(os.path.isfile(pkg))

    def test_corrupt_download_is_refused(self):
        urls, _ = _repo(self.files)
        bad = opener_for(urls, corrupt=_payload.file_url("puppy_companion/__init__.py"))
        with self.assertRaises(self.update.UpdateError):
            self.update.download(self.update.check(opener=opener_for(urls)), opener=bad)
        self.assertIsNone(self.update.installed_version())  # nothing left active

    def test_bad_python_is_refused(self):
        self.files["puppy_companion/__init__.py"] = b"def oops(:\n"  # syntax error
        urls, _ = _repo(self.files)
        with self.assertRaises(self.update.UpdateError):
            self.update.download(self.update.check(opener=opener_for(urls)), opener=opener_for(urls))
        self.assertIsNone(self.update.installed_version())

    def test_manifest_outside_package_refused(self):
        urls, manifest = _repo(self.files)
        manifest["files"].append({"path": "../evil.py", "sha256": "0" * 64, "size": 1})
        urls[_payload.manifest_url()] = json.dumps(manifest).encode()
        with self.assertRaises(self.update.UpdateError):
            self.update.check(opener=opener_for(urls))

    def test_bootstrap_loads_the_update(self):
        urls, _ = _repo(self.files)
        self.update.download(self.update.check(opener=opener_for(urls)), opener=opener_for(urls))
        import run_companion
        run_companion = importlib.reload(run_companion)
        # the bundled package is older; the bootstrap should swap in the downloaded one
        for m in [m for m in sys.modules if m == "puppy_companion" or m.startswith("puppy_companion.")]:
            del sys.modules[m]
        run_companion._activate_update()
        import puppy_companion
        self.assertEqual(getattr(puppy_companion, "SENTINEL", None), "updated-package")
        self.assertEqual(puppy_companion.__version__, "9.9.9")

    def test_latest_script_build(self):
        url = _payload.raw_base() + "PuppyAdmin.lua"
        head = b'-- Puppy Admin\nlocal SCRIPT_BUILD = "2026.11.24-50"\n'
        self.assertEqual(self.update.latest_script_build(opener=opener_for({url: head})), "2026.11.24-50")
        self.assertIsNone(self.update.latest_script_build(opener=opener_for({url: b"-- nothing"})))
        with self.assertRaises(self.update.UpdateError):
            self.update.latest_script_build(opener=opener_for({}))

    def test_build_order(self):
        bt = self.update.build_tuple
        self.assertGreater(bt("2026.11.24-50"), bt("2026.11.24-9"))
        self.assertGreater(bt("2026.11.25-1"), bt("2026.11.24-50"))
        self.assertEqual(bt(""), (0,))

    def test_files_come_from_one_commit(self):
        # the branch URLs are stale (old cached content); the commit URLs are current
        sha = "a" * 40
        urls, manifest = _repo(self.files)
        pinned = {}
        for url, data in urls.items():
            pinned[url.replace("/" + _payload.REPO_BRANCH + "/", "/" + sha + "/")] = data
        stale = {url: b"stale" for url in urls if url != _payload.manifest_url()}
        stale[_payload.manifest_url()] = urls[_payload.manifest_url()]
        api = "https://api.github.com/repos/%s/%s/commits/%s" % (
            _payload.REPO_OWNER, _payload.REPO_NAME, _payload.REPO_BRANCH)
        all_urls = dict(stale)
        all_urls.update(pinned)
        all_urls[api] = sha.encode()
        op = opener_for(all_urls)
        got = self.update.check(opener=op)
        self.assertEqual(got["_ref"], sha)
        self.assertEqual(self.update.download(got, opener=op), "9.9.9")


if __name__ == "__main__":
    unittest.main()
