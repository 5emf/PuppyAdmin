"""Pupdates driving your own Discord bot (instead of a webhook): sign in with the bot's token, pick a
server and channel, post (cards, plain text, pictures, pings), publish in announcement channels,
edit or delete what the bot posted, and change the bot's name and picture.

Discord API v10 over HTTPS with the standard library. The token goes only to discord.com, is stored
encrypted (DPAPI, like the webhook) and is hidden in every message the app shows.
"""
import base64
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from . import core

API = "https://discord.com/api/v10"
USER_AGENT = "DiscordBot (https://github.com/5emf/PuppyAdmin, 2) Pupdates"
TEXT, ANNOUNCEMENT, CATEGORY = 0, 5, 4
# View Channel, Send Messages, Embed Links, Attach Files, Read Message History, Mention Everyone
PERMISSIONS = 1024 | 2048 | 16384 | 32768 | 65536 | 131072
TOKEN_RE = re.compile(r"^[\w-]{18,}\.[\w-]{4,}\.[\w-]{20,}$")
TOKEN_ANYWHERE = re.compile(r"[\w-]{18,}\.[\w-]{4,}\.[\w-]{20,}")
ERRORS = {
    10003: "That channel no longer exists (or the bot cannot see it)",
    10008: "That message no longer exists",
    50001: "The bot cannot see that channel (give its role View Channel there)",
    50013: "The bot is missing a permission in that channel: it needs View Channel, Send Messages, Embed Links and "
           "Attach Files (and Mention Everyone for @here / @everyone)",
    50035: "Discord did not accept the message (too long or empty)",
    40005: "The picture is too big for Discord",
}


def valid_token(token):
    return bool(TOKEN_RE.match((token or "").strip()))


def hide(text, token=None):
    t = TOKEN_ANYWHERE.sub("***", str(text))
    return t.replace(token, "***") if token else t


def app_id_from_token(token):
    """The bot's id is the first part of its token (base64 of the id)."""
    part = (token or "").split(".")[0]
    try:
        raw = base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)).decode("ascii")
    except (ValueError, UnicodeDecodeError):
        return None
    return raw if raw.isdigit() else None


def invite_url(app_id):
    return ("https://discord.com/oauth2/authorize?client_id=%s&scope=bot&permissions=%d" % (app_id, PERMISSIONS)) if app_id else None


def jump_url(guild_id, channel_id, message_id):
    return "https://discord.com/channels/%s/%s/%s" % (guild_id or "@me", channel_id, message_id)


def bot_body(body):
    """A webhook body made fit for a bot: bots keep their own name and picture."""
    out = dict(body)
    out.pop("username", None)
    out.pop("avatar_url", None)
    return out


def sort_channels(channels):
    """Text and announcement channels in Discord's order (by category, then position), with the category name."""
    cats = {c["id"]: c for c in channels if c.get("type") == CATEGORY}
    usable = [c for c in channels if c.get("type") in (TEXT, ANNOUNCEMENT)]

    def key(c):
        cat = cats.get(c.get("parent_id"))
        return (cat.get("position", 0) if cat else -1, cat["id"] if cat else "", c.get("position", 0), c.get("name", ""))
    out = []
    for c in sorted(usable, key=key):
        cat = cats.get(c.get("parent_id"))
        out.append({"id": c["id"], "name": c.get("name", "?"), "type": c.get("type"), "category": cat.get("name", "") if cat else ""})
    return out


class BotError(RuntimeError):
    pass


class Bot:
    def __init__(self, token, opener=None, sleep=time.sleep):
        self.token = (token or "").strip()
        self.opener = opener or urllib.request.urlopen
        self.sleep = sleep

    def _call(self, method, path, body=None, image=None, tries=3):
        if not valid_token(self.token):
            raise BotError("That is not a bot token (Discord Developer Portal > your app > Bot > Reset Token)")
        headers = {"Authorization": "Bot " + self.token, "User-Agent": USER_AGENT}
        data = None
        if image is not None:
            data, ctype = core.multipart([("payload_json", json.dumps(body or {}))],
                                         [("files[0]", image["name"], image["mime"], image["data"])])
            headers["Content-Type"] = ctype
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        for attempt in range(tries):
            req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
            try:
                with self.opener(req, timeout=30) as r:
                    raw = r.read()
                    return json.loads(raw.decode("utf-8")) if raw else {}
            except urllib.error.HTTPError as e:
                try:
                    info = json.loads(e.read().decode("utf-8"))
                except (ValueError, AttributeError, UnicodeDecodeError):
                    info = {}
                if e.code == 429 and attempt < tries - 1:
                    self.sleep(min(float(info.get("retry_after") or 1.5), 30))
                    continue
                if e.code == 401:
                    raise BotError("Discord refused the token: it is wrong or was reset (make a new one in the Developer Portal)")
                if e.code == 429:
                    raise BotError("Discord says slow down: try again in a minute (a bot's name can change only twice an hour)")
                msg = ERRORS.get(info.get("code")) or info.get("message") or "HTTP %d" % e.code
                raise BotError(hide(msg, self.token))
            except (urllib.error.URLError, OSError) as e:
                raise BotError(hide("Could not reach Discord: %s" % getattr(e, "reason", e), self.token))
        raise BotError("Discord is still rate-limiting: try again in a minute")

    # who / where
    def me(self):
        return self._call("GET", "/users/@me")

    def guilds(self):
        return sorted(self._call("GET", "/users/@me/guilds"), key=lambda g: g.get("name", "").lower())

    def channels(self, guild_id):
        return sort_channels(self._call("GET", "/guilds/%s/channels" % guild_id))

    # posts
    def post(self, channel_id, body, image=None):
        return self._call("POST", "/channels/%s/messages" % channel_id, bot_body(body), image)

    def publish(self, channel_id, message_id):
        """Announcement channels: send the post on to every server that follows the channel."""
        return self._call("POST", "/channels/%s/messages/%s/crosspost" % (channel_id, message_id))

    def message(self, channel_id, message_id):
        return self._call("GET", "/channels/%s/messages/%s" % (channel_id, message_id))

    def edit(self, channel_id, message_id, body):
        """Replaces the text / card; a picture already on the post stays (kept by its attachment id)."""
        old = self.message(channel_id, message_id)
        new = bot_body(body)
        files = old.get("attachments") or []
        if files:
            new["attachments"] = [{"id": a["id"]} for a in files]
            for e in new.get("embeds") or []:
                if e.get("image", {}).get("url", "").startswith("attachment://"):
                    e["image"] = {"url": "attachment://" + files[0].get("filename", "pupdates.png")}
        else:
            for e in new.get("embeds") or []:
                e.pop("image", None)
        return self._call("PATCH", "/channels/%s/messages/%s" % (channel_id, message_id), new)

    def delete(self, channel_id, message_id):
        return self._call("DELETE", "/channels/%s/messages/%s" % (channel_id, message_id))

    # the bot itself
    def set_profile(self, username=None, avatar=None, clear_avatar=False):
        """username: new name (Discord allows about two changes an hour); avatar: load_image() result."""
        body = {}
        if username:
            body["username"] = username[:32]
        if avatar is not None:
            body["avatar"] = core.avatar_data_uri(avatar)
        elif clear_avatar:
            body["avatar"] = None
        if not body:
            raise BotError("Nothing to change")
        return self._call("PATCH", "/users/@me", body)


def avatar_url(user):
    """The bot's picture (Discord's CDN), or None when it has none."""
    if user.get("avatar"):
        return "https://cdn.discordapp.com/avatars/%s/%s.png?size=64" % (user["id"], user["avatar"])
    return None


def remember(posts, entry, keep=20):
    """Adds a post to the recent list (newest first, at most `keep`)."""
    posts = [p for p in posts if not (p.get("message") == entry["message"])]
    return ([entry] + posts)[:keep]
