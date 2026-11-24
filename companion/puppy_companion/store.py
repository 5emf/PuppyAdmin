"""Accounts (accounts.json, cookies encrypted) and settings (settings.json, nothing secret)."""
import base64
import json
import os
import tempfile
import threading
import time
from dataclasses import asdict, dataclass

from .paths import data_dir

ROLES = ("main", "alt")


@dataclass
class Account:
    user_id: int
    name: str
    display_name: str = ""
    alias: str = ""
    role: str = "alt"
    added: float = 0.0
    secret: str = ""  # base64 of the encrypted login cookie

    @property
    def label(self):
        return self.alias or self.name


def atomic_write(path, text):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".tmp-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


class AccountStore:
    FILE = "accounts.json"

    def __init__(self, protector, folder=None):
        self.protector = protector
        self.folder = folder or data_dir()
        self.path = os.path.join(self.folder, self.FILE)
        self._lock = threading.RLock()
        self._accounts = []
        self.load()

    def load(self):
        with self._lock:
            self._accounts = []
            if not os.path.exists(self.path):
                return
            with open(self.path, "r", encoding="utf-8") as f:
                data = json.load(f)
            for raw in data.get("accounts", []):
                try:
                    acc = Account(
                        user_id=int(raw["user_id"]), name=str(raw["name"]),
                        display_name=str(raw.get("display_name", "")), alias=str(raw.get("alias", "")),
                        role=raw.get("role") if raw.get("role") in ROLES else "alt",
                        added=float(raw.get("added", 0)), secret=str(raw.get("secret", "")),
                    )
                except (KeyError, TypeError, ValueError):
                    continue
                self._accounts.append(acc)

    def save(self):
        with self._lock:
            data = {"version": 1, "accounts": [asdict(a) for a in self._accounts]}
            atomic_write(self.path, json.dumps(data, indent=2))

    def accounts(self):
        with self._lock:
            return list(self._accounts)

    def get(self, user_id):
        user_id = int(user_id)
        with self._lock:
            for a in self._accounts:
                if a.user_id == user_id:
                    return a
        return None

    def add_or_update(self, cookie, user, role="alt", alias=""):
        """user: {"id", "name", "displayName"} as Roblox returned it for this cookie."""
        if role not in ROLES:
            raise ValueError("role must be main or alt")
        secret = base64.b64encode(self.protector.protect(cookie.strip().encode("utf-8"))).decode("ascii")
        with self._lock:
            acc = self.get(user["id"])
            if acc is None:
                acc = Account(user_id=int(user["id"]), name=str(user["name"]), added=time.time())
                self._accounts.append(acc)
            acc.name = str(user["name"])
            acc.display_name = str(user.get("displayName") or user["name"])
            acc.secret = secret
            acc.role = role
            if alias:
                acc.alias = alias
            if role == "main":
                self._single_main(acc)
            self.save()
            return acc

    def _single_main(self, keep):
        for a in self._accounts:
            if a is not keep and a.role == "main":
                a.role = "alt"

    def remove(self, user_id):
        with self._lock:
            self._accounts = [a for a in self._accounts if a.user_id != int(user_id)]
            self.save()

    def set_role(self, user_id, role):
        if role not in ROLES:
            raise ValueError("role must be main or alt")
        with self._lock:
            acc = self.get(user_id)
            if acc is None:
                return
            acc.role = role
            if role == "main":
                self._single_main(acc)
            self.save()

    def set_alias(self, user_id, alias):
        with self._lock:
            acc = self.get(user_id)
            if acc is None:
                return
            acc.alias = alias.strip()[:40]
            self.save()

    def cookie(self, user_id):
        acc = self.get(user_id)
        if acc is None:
            raise KeyError("no such account")
        return self.protector.unprotect(base64.b64decode(acc.secret)).decode("utf-8")

    def main(self):
        for a in self.accounts():
            if a.role == "main":
                return a
        return None

    def alts(self):
        return [a for a in self.accounts() if a.role == "alt"]


class Settings:
    FILE = "settings.json"
    DEFAULTS = {
        "workspace": "",            # the executor's workspace folder (where PuppyAdmin/ lives)
        "launch_delay": 8,          # seconds between launches
        "multi_instance": True,     # let several Roblox windows run
        "bootstrapper_multi": False, # Fishstrap/Bloxstrap holds the lock instead of us
        "singleton_names": "ROBLOX_singletonMutex, ROBLOX_singletonEvent",
        "place": "",
        "job": "",
    }

    def __init__(self, folder=None):
        self.path = os.path.join(folder or data_dir(), self.FILE)
        self._data = dict(self.DEFAULTS)
        try:
            with open(self.path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict):
                for k in self.DEFAULTS:
                    if k in saved:
                        self._data[k] = saved[k]
        except (OSError, ValueError):
            pass

    def get(self, key):
        return self._data.get(key, self.DEFAULTS.get(key))

    def set(self, key, value):
        self._data[key] = value
        atomic_write(self.path, json.dumps(self._data, indent=2))
