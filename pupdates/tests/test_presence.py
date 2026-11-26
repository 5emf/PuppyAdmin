"""Bot status (gateway.py) and rich presence (richpresence.py), no network: fake sockets and pipes."""
import io
import json
import os
import queue
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from pupdates_app import core, gateway, richpresence  # noqa: E402

try:
    import tkinter as tk
    from pupdates_app.app import PupdatesApp
except ImportError:  # pragma: no cover
    tk = None


def token():
    return ".".join(["MTIzNDU2Nzg5MDEyMzQ1Njc4", "Ga" + "BcDe", "abcdefghijklmnop" + "qrstuvwxyz012345"])


def server_frame(opcode, payload, fin=True):
    """A frame the way a server sends it (not masked)."""
    head = bytes([(0x80 if fin else 0) | opcode])
    n = len(payload)
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + payload


def read_client_frame(sock):
    """(opcode, payload) of one masked frame from the client."""
    def need(n):
        out = b""
        while len(out) < n:
            out += sock.recv(n - len(out))
        return out
    b1, b2 = need(2)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack(">H", need(2))[0]
    elif n == 127:
        n = struct.unpack(">Q", need(8))[0]
    assert b2 & 0x80, "client frames must be masked"
    mask = need(4)
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(need(n)))
    return b1 & 0x0F, data


class WebSocketTest(unittest.TestCase):
    def test_accept_key_matches_the_rfc_example(self):
        self.assertEqual(gateway.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

    def test_frames_of_every_length_round_trip(self):
        for n in (0, 5, 125, 126, 1000, 65535, 65536, 70000):
            a, b = socket.socketpair()
            try:
                payload = bytes(i % 251 for i in range(n))
                a.sendall(gateway.frame(0x1, payload, mask=b"\x01\x02\x03\x04"))
                result = {}
                t = threading.Thread(target=lambda: result.update(f=read_client_frame(b)))
                t.start()
                t.join(5)
                self.assertEqual(result["f"], (0x1, payload), n)
            finally:
                a.close()
                b.close()

    def test_handshake_texts_pings_fragments_and_close(self):
        a, b = socket.socketpair()
        ws = gateway.WebSocket(a)

        def server():
            req = b""
            while b"\r\n\r\n" not in req:
                req += b.recv(4096)
            key = [l.split(":", 1)[1].strip() for l in req.decode().split("\r\n") if l.lower().startswith("sec-websocket-key")][0]
            b.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       "Sec-WebSocket-Accept: %s\r\n\r\n" % gateway.accept_key(key)).encode())
            b.sendall(server_frame(0x1, b'{"op":10}'))
            b.sendall(server_frame(0x9, b"hi"))                          # a ping: the client answers with a pong
            b.sendall(server_frame(0x1, b'{"a":', fin=False) + server_frame(0x0, b'1}'))
            pongs.put(read_client_frame(b))
            b.sendall(server_frame(0x8, struct.pack(">H", 4004) + b"Authentication failed."))

        pongs = queue.Queue()
        t = threading.Thread(target=server, daemon=True)
        t.start()
        try:
            ws.handshake("gateway.discord.gg", "/?v=10&encoding=json")
            self.assertEqual(ws.recv_text(), '{"op":10}')
            self.assertEqual(ws.recv_text(), '{"a":1}')
            self.assertEqual(pongs.get(timeout=5), (0xA, b"hi"))
            with self.assertRaises(gateway.Closed) as c:
                ws.recv_text()
            self.assertEqual(c.exception.code, 4004)
            self.assertIn("Authentication", c.exception.reason)
        finally:
            a.close()
            b.close()

    def test_a_wrong_accept_key_is_refused(self):
        a, b = socket.socketpair()
        try:
            b.sendall(b"HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: nope\r\n\r\n")
            with self.assertRaises(gateway.Closed):
                gateway.WebSocket(a).handshake("x", "/")
        finally:
            a.close()
            b.close()


class FakeGatewaySocket:
    """Plays Discord's side of a session: the test pushes messages, the client's sends are recorded."""

    def __init__(self):
        self.inbox = queue.Queue()
        self.sent = []
        self.closed = None

    def push(self, obj):
        self.inbox.put(obj)

    def recv_text(self):
        item = self.inbox.get(timeout=5)
        if isinstance(item, gateway.Closed):
            raise item
        return json.dumps(item)

    def send_text(self, text):
        self.sent.append(json.loads(text))

    def close(self, code=1000):
        self.closed = code
        self.inbox.put(gateway.Closed(code, "closed by the client"))


class BotPresenceTest(unittest.TestCase):
    def test_identify_carries_listening_to_jae_and_updates_change_it(self):
        self.assertEqual(gateway.presence("Listening", "Jae but mainly Claude"),
                         {"since": None, "activities": [{"name": "Jae but mainly Claude", "type": 2}], "status": "online", "afk": False})
        sockets, states = [], queue.Queue()

        def connect(url):
            self.assertEqual(url, gateway.GATEWAY)
            s = FakeGatewaySocket()
            s.push({"op": 10, "d": {"heartbeat_interval": 60000}})
            sockets.append(s)
            return s

        p = gateway.BotPresence(token(), "Listening", "Jae but mainly Claude", on_state=lambda t, ok: states.put((t, ok)),
                                connect=connect, sleep=lambda s: None)
        p.start()
        deadline = time.time() + 5
        while not (sockets and sockets[0].sent) and time.time() < deadline:
            time.sleep(0.01)
        s = sockets[0]
        ident = s.sent[0]
        self.assertEqual(ident["op"], 2)
        self.assertEqual(ident["d"]["token"], token())
        self.assertEqual(ident["d"]["intents"], 0)
        self.assertEqual(ident["d"]["presence"]["activities"], [{"name": "Jae but mainly Claude", "type": 2}])
        s.push({"op": 0, "t": "READY", "s": 1, "d": {"user": {"username": "Pupdates"}}})
        self.assertEqual(states.get(timeout=5), ("Online as Pupdates - Listening Jae but mainly Claude", True))
        s.push({"op": 1})                                  # Discord asks for a heartbeat now
        deadline = time.time() + 5
        while not any(m["op"] == 1 for m in s.sent) and time.time() < deadline:
            time.sleep(0.01)
        self.assertIn({"op": 1, "d": 1}, s.sent)

        p.set_presence("Watching", "the servers", "idle")
        self.assertEqual(s.sent[-1], {"op": 3, "d": {"since": None, "activities": [{"name": "the servers", "type": 3}],
                                                      "status": "idle", "afk": False}})
        p.stop()
        self.assertEqual(states.get(timeout=5), ("Offline (stopped).", False))

    def test_a_wrong_token_stops_for_good(self):
        tries, states = [], queue.Queue()

        def connect(url):
            s = FakeGatewaySocket()
            s.push({"op": 10, "d": {"heartbeat_interval": 60000}})
            s.push(gateway.Closed(4004, "Authentication failed."))
            tries.append(s)
            return s

        p = gateway.BotPresence(token(), "Listening", "x", on_state=lambda t, ok: states.put((t, ok)), connect=connect)
        p.run()
        self.assertEqual(len(tries), 1)
        text, ok = states.get(timeout=1)
        self.assertFalse(ok)
        self.assertIn("refused the bot's token", text)

    def test_a_dropped_link_reconnects(self):
        tries, states = [], queue.Queue()

        def connect(url):
            s = FakeGatewaySocket()
            s.push({"op": 10, "d": {"heartbeat_interval": 60000}})
            if not tries:
                s.push({"op": 7})                          # "reconnect, please"
            tries.append(s)
            return s

        p = gateway.BotPresence(token(), "Listening", "x", on_state=lambda t, ok: states.put((t, ok)), connect=connect,
                                wait=lambda seconds: None)     # no 5 s pause in the test
        t = threading.Thread(target=p.run, daemon=True)
        t.start()
        deadline = time.time() + 5
        while len(tries) < 2 and time.time() < deadline:
            time.sleep(0.01)
        self.assertEqual(len(tries), 2)
        self.assertIn("Reconnecting", states.get(timeout=1)[0])
        p.stop()
        t.join(5)


class FakePipe:
    """The Discord app's side of the IPC pipe."""

    def __init__(self, refuse_type=False, bad_app=False):
        self.out = io.BytesIO()
        self.replies = []
        self.refuse_type = refuse_type
        self.bad_app = bad_app
        self.sent = []
        self.closed = False

    def write(self, data):
        op, n = struct.unpack("<II", data[:8])
        msg = json.loads(data[8:8 + n])
        self.sent.append((op, msg))
        if op == 0:
            reply = ({"code": 4000, "message": "Invalid Client ID"} if self.bad_app else
                     {"cmd": "DISPATCH", "evt": "READY", "data": {"user": {"username": "jae"}}})
            self.replies.append(richpresence.pack(2 if self.bad_app else 1, reply))
        else:
            act = msg["args"]["activity"]
            if self.refuse_type and act and "type" in act:
                reply = {"cmd": "SET_ACTIVITY", "evt": "ERROR", "data": {"code": 4000, "message": "child \"activity\" fails because [\"type\" is not allowed]"}}
            else:
                reply = {"cmd": "SET_ACTIVITY", "data": act, "nonce": msg["nonce"]}
            self.replies.append(richpresence.pack(1, reply))
        self.buf = io.BytesIO(b"".join(self.replies))
        self.replies = []
        return len(data)

    def read(self, n):
        return self.buf.read(n)

    def close(self):
        self.closed = True


class RichPresenceTest(unittest.TestCase):
    def test_frames_round_trip(self):
        data = richpresence.pack(1, {"cmd": "SET_ACTIVITY", "x": "é"})
        self.assertEqual(struct.unpack("<II", data[:8])[0], 1)
        self.assertEqual(richpresence.unpack(io.BytesIO(data).read), (1, {"cmd": "SET_ACTIVITY", "x": "é"}))
        with self.assertRaises(ConnectionError):
            richpresence.unpack(io.BytesIO(b"\x01\x00").read)

    def test_the_owners_activity(self):
        act = richpresence.build_activity("Listening", "May Your Heart Be", "Your Guiding Key", 1795676718,
                                          "Join for more Pupdates", "https://discord.gg/eDC7V9bnAX")
        self.assertEqual(act, {"type": 2, "details": "May Your Heart Be", "state": "Your Guiding Key",
                               "timestamps": {"start": 1795676718},
                               "buttons": [{"label": "Join for more Pupdates", "url": "https://discord.gg/eDC7V9bnAX"}]})
        self.assertEqual(richpresence.build_activity("Playing", "", "", None, "Join", "not a link"), {"type": 0})
        self.assertEqual(richpresence.build_activity("Listening", "a", "", None, image="logo")["assets"], {"large_image": "logo"})
        s = core.Settings(tempfile.mkdtemp())
        self.assertEqual((s.get("rp_details"), s.get("rp_state"), s.get("rp_start"), s.get("rp_button_label"), s.get("rp_button_url")),
                         ("May Your Heart Be", "Your Guiding Key", "1795676718", "Join for more Pupdates", "https://discord.gg/eDC7V9bnAX"))
        self.assertEqual((s.get("bot_activity_type"), s.get("bot_activity_text")), ("Listening", "Jae but mainly Claude"))
        shutil.rmtree(s.folder, ignore_errors=True)

    def test_button_links(self):
        self.assertEqual(richpresence.clean_url("discord.gg/abc"), "https://discord.gg/abc")
        self.assertEqual(richpresence.clean_url(" https://discord.gg/eDC7V9bnAX "), "https://discord.gg/eDC7V9bnAX")
        self.assertEqual(richpresence.clean_url("my server"), "")
        self.assertEqual(richpresence.clean_url("ftp://x.com"), "")
        act = richpresence.build_activity("Listening", "a", "b", None, "Join", "discord.gg/abc")
        self.assertEqual(act["buttons"], [{"label": "Join", "url": "https://discord.gg/abc"}])
        self.assertIn("not a link", richpresence.button_note("Join", "my server"))
        self.assertIn("give it a text", richpresence.button_note("", "discord.gg/abc"))
        self.assertIn("opens https://discord.gg/abc", richpresence.button_note("Join", "discord.gg/abc"))
        rp = self._rp(FakePipe())
        text = rp.connect_once()
        self.assertIn("Join for more Pupdates", text)
        self.assertIn("never shows your own buttons", text)
        self.assertEqual(rp.activity["buttons"][0]["url"], "https://discord.gg/eDC7V9bnAX")

    def _rp(self, pipe, app_id="1575303315123456789"):
        act = richpresence.build_activity("Listening", "May Your Heart Be", "Your Guiding Key", 1795676718,
                                          "Join for more Pupdates", "https://discord.gg/eDC7V9bnAX")
        return richpresence.RichPresence(app_id, act, pipe_factory=lambda: richpresence.Pipe(opener=lambda path: pipe))

    def test_hello_then_set_activity(self):
        pipe = FakePipe()
        rp = self._rp(pipe)
        self.assertTrue(rp.connect_once().startswith("Showing on jae's profile. Button"))
        self.assertEqual(pipe.sent[0], (0, {"v": 1, "client_id": "1575303315123456789"}))
        op, msg = pipe.sent[1]
        self.assertEqual((op, msg["cmd"], msg["args"]["pid"]), (1, "SET_ACTIVITY", os.getpid()))
        self.assertEqual(msg["args"]["activity"]["details"], "May Your Heart Be")
        rp.stop()
        self.assertIsNone(pipe.sent[-1][1]["args"]["activity"])      # cleared on stop
        self.assertTrue(pipe.closed)

    def test_falls_back_when_the_app_refuses_the_type(self):
        pipe = FakePipe(refuse_type=True)
        rp = self._rp(pipe)
        self.assertIn("only shows Playing", rp.connect_once())
        self.assertNotIn("type", pipe.sent[-1][1]["args"]["activity"])

    def test_readable_refusals(self):
        with self.assertRaises(ValueError) as c:
            self._rp(FakePipe(bad_app=True)).connect_once()
        self.assertIn("Invalid Client ID", str(c.exception))
        with self.assertRaises(ValueError):
            self._rp(FakePipe(), app_id="").connect_once()

        def nothing(path):
            raise FileNotFoundError(path)
        with self.assertRaises(ConnectionError) as c:
            richpresence.Pipe(opener=nothing).open()
        self.assertIn("not running", str(c.exception))

    def test_keeps_retrying_until_discord_is_there(self):
        states = queue.Queue()
        pipes = [None, FakePipe()]

        def factory():
            p = pipes.pop(0)
            if p is None:
                return richpresence.Pipe(opener=lambda path: (_ for _ in ()).throw(FileNotFoundError(path)))
            return richpresence.Pipe(opener=lambda path: p)

        act = richpresence.build_activity("Listening", "a", "b")
        rp = richpresence.RichPresence("123", act, on_state=lambda t, ok: states.put((t, ok)), pipe_factory=factory,
                                       wait=lambda s: None)
        rp.start()
        self.assertIn("not running", states.get(timeout=5)[0])
        self.assertEqual(states.get(timeout=5), ("Showing on jae's profile. No button.", True))
        rp.update(richpresence.build_activity("Listening", "new", "b"))
        self.assertEqual(states.get(timeout=5), ("Updated. No button.", True))
        rp.stop()


class FakeProtector:
    def protect(self, b):
        return b"enc:" + b[::-1]

    def unprotect(self, b):
        return b[4:][::-1]


class StatusWindowTest(unittest.TestCase):
    def setUp(self):
        if tk is None:
            self.skipTest("no tkinter")
        try:
            self.root = tk.Tk()
        except tk.TclError as e:
            self.skipTest("no display: %s" % e)
        self.root.withdraw()
        self.folder = tempfile.mkdtemp()
        self.settings = core.Settings(self.folder, FakeProtector())
        self.started = []
        test = self

        class FakePresence:
            def __init__(self, tok, kind, text, status="online", on_state=None):
                self.args = [tok, kind, text, status]
                self.on_state = on_state
                self.updates = []
                self.stopped = False

            def start(self):
                test.started.append(self)
                self.on_state("Online as Pupdates - %s %s" % (self.args[1], self.args[2]), True)
                return self

            def set_presence(self, kind, text, status="online"):
                self.updates.append((kind, text, status))

            def stop(self):
                self.stopped = True

        self.real = gateway.BotPresence
        gateway.BotPresence = FakePresence
        self.app = PupdatesApp(self.root, self.settings, floating=False)

    def tearDown(self):
        if hasattr(self, "app"):
            self.app.close()
            gateway.BotPresence = self.real
        shutil.rmtree(self.folder, ignore_errors=True)

    def pump(self, until, seconds=3):
        end = time.time() + seconds
        while time.time() < end:
            self.root.update()
            if until():
                return True
            time.sleep(0.02)
        return False

    def test_status_section(self):
        self.app.show("status")
        self.assertEqual(self.app.bot_text_var.get(), "Jae but mainly Claude")
        self.assertEqual(self.app.bot_type_var.get(), "Listening")
        self.assertEqual(self.app.rp_vars["rp_details"].get(), "May Your Heart Be")
        self.app.bot_online_var.set(True)
        self.app.toggle_bot_presence()                      # no token yet: refused, switch goes back off
        self.assertFalse(self.app.bot_online_var.get())
        self.assertIn("token", self.app.bot_state_lbl.cget("text"))

        self.settings.set_secret("bot_token", token())
        self.app.bot_online_var.set(True)
        self.app.toggle_bot_presence()
        self.assertEqual(self.started[-1].args, [token(), "Listening", "Jae but mainly Claude", "online"])
        self.assertTrue(self.pump(lambda: "Online as Pupdates - Listening Jae but mainly Claude" in self.app.bot_state_lbl.cget("text")))
        self.assertTrue(self.settings.get("bot_online"))
        self.app.bot_text_var.set("Jae")
        self.app.apply_bot_presence()
        self.assertEqual(self.started[-1].updates, [("Listening", "Jae", "online")])
        self.app.bot_online_var.set(False)
        self.app.toggle_bot_presence()
        self.assertTrue(self.started[-1].stopped)

        self.app.rp_vars["rp_app_id"].set("")
        self.app.rp_app_from_bot()                           # the bot token's first part is the application id
        self.assertEqual(self.app.rp_vars["rp_app_id"].get(), "123456789012345678")
