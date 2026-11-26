"""Rich presence on YOUR Discord profile, the same thing the Social SDK snippet does, without the SDK:
Pupdates talks to the Discord desktop app on this PC through its local pipe (\\\\?\\pipe\\discord-ipc-N),
says hello with your application's id, then sets the activity: "Listening to <app name>", two
lines, a timer and up to two buttons. Windows only (phones' Discord apps have no such pipe).
Frames: op (uint32 LE), length (uint32 LE), JSON.
"""
import json
import os
import struct
import sys
import threading
import uuid

TYPES = {"Playing": 0, "Listening": 2, "Watching": 3, "Competing": 5}


def pack(op, payload):
    data = json.dumps(payload).encode("utf-8")
    return struct.pack("<II", op, len(data)) + data


def unpack(read):
    """(op, payload) from a read(n) function."""
    head = read(8)
    if len(head) < 8:
        raise ConnectionError("Discord closed the connection")
    op, n = struct.unpack("<II", head)
    data = read(n) if n else b""
    return op, (json.loads(data.decode("utf-8")) if data else {})


def build_activity(kind, details, state, start=None, button_label="", button_url="", image=""):
    """The activity Discord shows; empty parts are left out. start = Unix seconds or None."""
    act = {"type": TYPES.get(kind, 2)}
    if details.strip():
        act["details"] = details.strip()[:128]
    if state.strip():
        act["state"] = state.strip()[:128]
    if start:
        act["timestamps"] = {"start": int(start)}
    if button_label.strip() and button_url.strip().startswith(("https://", "http://")):
        act["buttons"] = [{"label": button_label.strip()[:32], "url": button_url.strip()[:512]}]
    if image.strip():
        act["assets"] = {"large_image": image.strip()[:256]}
    return act


class Pipe:
    """The Discord desktop app's local pipe (the first of discord-ipc-0 .. 9 that opens)."""

    def __init__(self, opener=None):
        self.f = None
        self.opener = opener

    def open(self):
        opener = self.opener
        if opener is None:
            if sys.platform != "win32":
                raise ConnectionError("rich presence needs the Discord desktop app on Windows")
            opener = lambda path: open(path, "r+b", buffering=0)  # noqa: E731
        for i in range(10):
            try:
                self.f = opener(r"\\?\pipe\discord-ipc-%d" % i)
                return self
            except OSError:
                continue
        raise ConnectionError("the Discord desktop app is not running on this PC")

    def send(self, op, payload):
        self.f.write(pack(op, payload))

    def recv(self):
        def read(n):
            out = b""
            while len(out) < n:
                chunk = self.f.read(n - len(out))
                if not chunk:
                    break
                out += chunk
            return out
        return unpack(read)

    def close(self):
        if self.f:
            try:
                self.f.close()
            except OSError:
                pass
        self.f = None


class RichPresence:
    """Keeps your profile's activity set while Pupdates runs (reconnects when the Discord app restarts).
    on_state(text, ok) is called from its thread."""

    def __init__(self, app_id, activity, on_state=None, pipe_factory=Pipe, wait=None):
        self.app_id = str(app_id).strip()
        self.activity = activity
        self.on_state = on_state or (lambda text, ok: None)
        self.pipe_factory = pipe_factory
        self.stopped = threading.Event()
        self.changed = threading.Event()
        self.wait = wait or self.stopped.wait
        self.pipe = None
        self.lock = threading.Lock()

    def start(self):
        threading.Thread(target=self.run, daemon=True).start()
        return self

    def stop(self):
        self.stopped.set()
        self.changed.set()
        got = self.lock.acquire(timeout=2)     # never hang the window on a stuck pipe
        try:
            if self.pipe:
                if got:
                    try:
                        self._set(None)            # clears the activity on your profile
                    except Exception:
                        pass
                self.pipe.close()
                self.pipe = None
        finally:
            if got:
                self.lock.release()

    def update(self, activity):
        self.activity = activity
        self.changed.set()

    def _set(self, activity):
        self.pipe.send(1, {"cmd": "SET_ACTIVITY", "args": {"pid": os.getpid(), "activity": activity}, "nonce": str(uuid.uuid4())})
        op, reply = self.pipe.recv()
        if reply.get("evt") == "ERROR":
            raise ValueError((reply.get("data") or {}).get("message") or "Discord refused the activity")
        return reply

    def connect_once(self):
        """One connect + set; raises with a readable reason."""
        if not self.app_id.isdigit():
            raise ValueError("Enter your application's id (Developer Portal > your app > General Information > Application ID)")
        pipe = self.pipe_factory().open()
        pipe.send(0, {"v": 1, "client_id": self.app_id})
        op, ready = pipe.recv()
        if op == 2 or ready.get("evt") != "READY":
            pipe.close()
            raise ValueError((ready.get("message") or (ready.get("data") or {}).get("message") or "Discord refused the application id"))
        with self.lock:
            self.pipe = pipe
        try:
            self._set(self.activity)
            note = ""
        except ValueError as e:
            if "type" not in str(e).lower():
                raise
            act = dict(self.activity)
            act.pop("type", None)              # an older Discord app: only "Playing" is allowed
            self._set(act)
            note = " (this Discord app version only shows Playing)"
        user = (ready.get("data") or {}).get("user") or {}
        return "Showing on %s's profile%s." % (user.get("username", "your"), note)

    def run(self):
        while not self.stopped.is_set():
            try:
                self.on_state(self.connect_once(), True)
                while not self.stopped.is_set():           # keep the pipe open; resend when the fields change
                    self.changed.wait(15)
                    if self.stopped.is_set():
                        break
                    if self.changed.is_set():
                        self.changed.clear()
                        with self.lock:
                            self._set(self.activity)
                        self.on_state("Updated.", True)
                    else:
                        with self.lock:                  # a quiet check that Discord is still there
                            self._set(self.activity)
            except (ConnectionError, OSError, ValueError) as e:
                with self.lock:
                    if self.pipe:
                        self.pipe.close()
                    self.pipe = None
                if self.stopped.is_set():
                    break
                self.on_state("Not showing: %s. Trying again in 20 s..." % e, False)
                self.wait(20)
