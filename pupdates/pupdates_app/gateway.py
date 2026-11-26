"""Keeps the bot online with a status ("Listening to ...") while Pupdates runs: a small WebSocket
client (standard library only) and Discord's gateway (v10): Hello -> Identify with the presence ->
heartbeats; the status can change while connected (op 3). Reconnects with growing pauses; a wrong
token stops it with a clear message. Bots can show one line only (no second line, timer or buttons).
"""
import base64
import hashlib
import json
import os
import random
import socket
import ssl
import struct
import threading
import time
import urllib.parse

GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"
TYPES = {"Playing": 0, "Listening": 2, "Watching": 3, "Competing": 5}
STATUSES = ("online", "idle", "dnd")
_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Closed(Exception):
    def __init__(self, code=None, reason=""):
        super().__init__("closed %s %s" % (code, reason))
        self.code, self.reason = code, reason


# ------------------------------------------------------------------ WebSocket (RFC 6455, client side)
def frame(opcode, payload, mask=None):
    """One masked, final frame (clients must mask)."""
    mask = mask if mask is not None else os.urandom(4)
    head = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([0x80 | n])
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    return head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload))


def accept_key(key):
    return base64.b64encode(hashlib.sha1((key + _GUID).encode()).digest()).decode()


class WebSocket:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.lock = threading.Lock()

    @classmethod
    def connect(cls, url, timeout=30):
        u = urllib.parse.urlparse(url)
        host, port = u.hostname, u.port or 443
        raw = socket.create_connection((host, port), timeout=timeout)
        sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        ws = cls(sock)
        ws.handshake(host, (u.path or "/") + ("?" + u.query if u.query else ""))
        sock.settimeout(None)
        return ws

    def handshake(self, host, path):
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Pupdates\r\n\r\n"
                           % (path, host, key)).encode())
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise Closed(None, "the server closed during the handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise Closed(None, "the server refused the WebSocket (%s)" % lines[0])
        headers = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        if headers.get("sec-websocket-accept") != accept_key(key):
            raise Closed(None, "bad WebSocket handshake")

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Closed(None, "connection lost")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, opcode, payload):
        with self.lock:
            self.sock.sendall(frame(opcode, payload))

    def send_text(self, text):
        self.send(0x1, text.encode("utf-8"))

    def recv_text(self):
        """The next text message (pings answered, fragments joined). Raises Closed."""
        parts = []
        while True:
            b1, b2 = self._read(2)
            fin, op, n = b1 & 0x80, b1 & 0x0F, b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b2 & 0x80 else None
            data = self._read(n)
            if mask:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if op == 0x9:
                self.send(0xA, data)
                continue
            if op == 0xA:
                continue
            if op == 0x8:
                code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else None
                raise Closed(code, data[2:].decode("utf-8", "replace"))
            parts.append(data)
            if fin:
                return b"".join(parts).decode("utf-8")

    def close(self, code=1000):
        try:
            self.send(0x8, struct.pack(">H", code))
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


# ------------------------------------------------------------------ the gateway
FATAL = {4004: "Discord refused the bot's token (it is wrong or was reset)",
         4010: "Discord says the shard settings are invalid", 4011: "The bot is in too many servers to connect without sharding",
         4013: "Discord says the intents are invalid", 4014: "Discord says the intents are not allowed"}


def activity(kind, text):
    text = (text or "").strip()[:128]
    return {"name": text, "type": TYPES.get(kind, 2)} if text else None


def presence(kind, text, status="online"):
    act = activity(kind, text)
    return {"since": None, "activities": [act] if act else [], "status": status if status in STATUSES else "online", "afk": False}


def identify(token, pres):
    return {"op": 2, "d": {"token": token, "intents": 0, "presence": pres,
                           "properties": {"os": "windows", "browser": "Pupdates", "device": "Pupdates"}}}


class BotPresence:
    """Runs in its own thread: connect, identify, heartbeat, reconnect. on_state(text, online) is called
    from that thread (the window passes it on to its own thread)."""

    def __init__(self, token, kind, text, status="online", on_state=None, connect=WebSocket.connect, sleep=time.sleep, wait=None):
        self.token = token
        self.pres = presence(kind, text, status)
        self.on_state = on_state or (lambda text, online: None)
        self.connect = connect
        self.sleep = sleep
        self.ws = None
        self.seq = None
        self.stopped = threading.Event()
        self.wait = wait or self.stopped.wait      # the pause between reconnects (ends early on stop)
        self.thread = None
        self.acked = True

    def start(self):
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()
        return self

    def stop(self):
        self.stopped.set()
        if self.ws:
            self.ws.close()

    def set_presence(self, kind, text, status="online"):
        self.pres = presence(kind, text, status)
        ws = self.ws
        if ws:
            try:
                ws.send_text(json.dumps({"op": 3, "d": self.pres}))
            except OSError:
                pass

    def run(self):
        pause = 5
        while not self.stopped.is_set():
            try:
                self.session()
                pause = 5
            except Closed as e:
                if e.code in FATAL:
                    self.on_state("Offline: " + FATAL[e.code], False)
                    return
                if not self.stopped.is_set():
                    self.on_state("Reconnecting (%s)..." % (e.reason or e.code or "connection lost"), False)
            except (OSError, ValueError) as e:
                if not self.stopped.is_set():
                    self.on_state("Offline: could not reach Discord (%s). Trying again..." % e, False)
            finally:
                if self.ws:
                    self.ws.close()
                self.ws = None
            if self.stopped.is_set():
                break
            self.wait(pause)
            pause = min(pause * 2, 120)
        self.on_state("Offline (stopped).", False)

    def _beat(self, ws, interval):
        first = interval * random.random()
        if self.stopped.wait(first):
            return
        while not self.stopped.is_set() and self.ws is ws:
            if not self.acked:          # no answer to the last heartbeat: the link is dead, start over
                ws.close(4000)
                return
            self.acked = False
            try:
                ws.send_text(json.dumps({"op": 1, "d": self.seq}))
            except OSError:
                return
            if self.stopped.wait(interval):
                return

    def session(self):
        ws = self.connect(GATEWAY)
        self.ws = ws
        hello = json.loads(ws.recv_text())
        if hello.get("op") != 10:
            raise Closed(None, "Discord did not say hello")
        interval = hello["d"]["heartbeat_interval"] / 1000.0
        self.acked = True
        threading.Thread(target=self._beat, args=(ws, interval), daemon=True).start()
        ws.send_text(json.dumps(identify(self.token, self.pres)))
        while not self.stopped.is_set():
            msg = json.loads(ws.recv_text())
            op = msg.get("op")
            if msg.get("s") is not None:
                self.seq = msg["s"]
            if op == 11:
                self.acked = True
            elif op == 1:
                ws.send_text(json.dumps({"op": 1, "d": self.seq}))
            elif op == 0 and msg.get("t") == "READY":
                me = msg["d"].get("user", {})
                act = self.pres["activities"][0] if self.pres["activities"] else None
                what = (" - %s %s" % ([k for k, v in TYPES.items() if v == act["type"]][0], act["name"])) if act else ""
                self.on_state("Online as %s%s" % (me.get("username", "the bot"), what), True)
            elif op == 7:
                raise Closed(None, "Discord asked to reconnect")
            elif op == 9:
                self.sleep(random.uniform(1, 5))
                raise Closed(None, "the session was not accepted")
