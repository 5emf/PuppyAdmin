"""The few Roblox web calls the companion needs. The cookie only ever goes to roblox.com."""
import json
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PuppyCompanion/1.0"
AUTH_URL = "https://users.roblox.com/v1/users/authenticated"
TICKET_URL = "https://auth.roblox.com/v1/authentication-ticket/"
PRESENCE_URL = "https://presence.roblox.com/v1/presence/users"

# Account management (Manage tab). These paths are Roblox's public web API as
# remembered, NOT checked against Roblox's docs from the build machine (its network
# could not reach roblox.com). Every call reports Roblox's exact status on failure,
# so a moved endpoint shows up as a clear error instead of a silent no-op. The
# privacy dropdowns are built from whatever options Roblox itself returns; no
# option values are hard-coded. Confirm on a live account before relying on them.
ENDPOINTS = {
    "user": "https://users.roblox.com/v1/users/{user_id}",                      # GET: name, displayName, description
    "display_name": "https://users.roblox.com/v1/users/{user_id}/display-names", # PATCH {"newDisplayName"}
    "description": "https://users.roblox.com/v1/description",                    # POST {"description"}
    "settings_options": "https://apis.roblox.com/user-settings-api/v1/user-settings/settings-and-options",  # GET
    "settings": "https://apis.roblox.com/user-settings-api/v1/user-settings",    # GET / POST {key: value}
    "logout_all": "https://auth.roblox.com/v1/logoutfromallsessionsandreauthenticate",  # POST; new cookie in Set-Cookie
    "headshot": ("https://thumbnails.roblox.com/v1/users/avatar-headshot"
                 "?userIds={user_id}&size=150x150&format=Png&isCircular=false"),  # GET, no login sent
}
WEB_HEADERS = {"Referer": "https://www.roblox.com/", "Origin": "https://www.roblox.com"}


class RobloxError(Exception):
    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def _default_opener(request, timeout):
    return urllib.request.urlopen(request, timeout=timeout)


def _error_text(raw):
    try:
        data = json.loads(raw)
    except (ValueError, TypeError):
        return ""
    errors = data.get("errors") if isinstance(data, dict) else None
    if isinstance(errors, list) and errors and isinstance(errors[0], dict):
        return str(errors[0].get("message", ""))[:160]
    return ""


class RobloxSession:
    def __init__(self, cookie, opener=None, timeout=15):
        cookie = (cookie or "").strip()
        if not cookie:
            raise RobloxError("No login cookie was given.")
        self._cookie = cookie
        self._open = opener or _default_opener
        self._timeout = timeout
        self._csrf = ""

    def __repr__(self):
        return "<RobloxSession>"  # never print the cookie

    def _send(self, method, url, body, extra):
        headers = {
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            "Cookie": ".ROBLOSECURITY=" + self._cookie,
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if self._csrf:
            headers["X-CSRF-TOKEN"] = self._csrf
        headers.update(extra or {})
        request = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with self._open(request, self._timeout) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read()
        except urllib.error.URLError as e:
            raise RobloxError("Could not reach Roblox (%s)." % (e.reason,))
        except OSError as e:
            raise RobloxError("Could not reach Roblox (%s)." % (e,))

    def _request(self, method, url, body=None, extra=None):
        status, headers, raw = self._send(method, url, body, extra)
        token = headers.get("x-csrf-token") if headers is not None else None
        # Roblox answers the first write request with 403 and a token to repeat it with
        if status == 403 and token and token != self._csrf:
            self._csrf = token
            status, headers, raw = self._send(method, url, body, extra)
        return status, headers, raw

    @staticmethod
    def _fail(status, raw, what):
        if status == 401:
            msg = ("Roblox says this login is no longer valid (logged out, expired or changed). "
                   "Add the account again with a new cookie.")
        elif status == 403:
            msg = "Roblox refused %s (403)." % what
        elif status == 429:
            msg = "Roblox is rate limiting %s: wait a minute and try again." % what
        else:
            msg = "Roblox answered %s to %s." % (status, what)
        detail = _error_text(raw)
        if detail:
            msg += " Roblox: " + detail
        raise RobloxError(msg, status)

    def authenticated_user(self):
        """{"id", "name", "displayName"} of the account this cookie belongs to."""
        status, _, raw = self._request("GET", AUTH_URL)
        if status != 200:
            self._fail(status, raw, "the login check")
        data = json.loads(raw)
        return {"id": int(data["id"]), "name": str(data["name"]),
                "displayName": str(data.get("displayName") or data["name"])}

    def auth_ticket(self):
        """One-time ticket the Roblox player uses to sign in as this account."""
        status, headers, raw = self._request(
            "POST", TICKET_URL, body={},
            extra={"Referer": "https://www.roblox.com/", "Origin": "https://www.roblox.com"})
        ticket = headers.get("rbx-authentication-ticket") if headers is not None else None
        if status == 200 and ticket:
            return ticket
        if status == 200:
            raise RobloxError("Roblox did not return a launch ticket.", status)
        self._fail(status, raw, "the launch ticket request")

    def presence(self, user_ids):
        """Presence entries: userPresenceType (2 = in a game), placeId, gameId (server), ..."""
        status, _, raw = self._request("POST", PRESENCE_URL, body={"userIds": [int(u) for u in user_ids]})
        if status != 200:
            self._fail(status, raw, "the presence check")
        return json.loads(raw).get("userPresences", [])

    # --- account management --------------------------------------------------------
    def _json(self, method, url, body, what, ok=(200,)):
        status, headers, raw = self._request(method, url, body=body, extra=WEB_HEADERS)
        if status not in ok:
            self._fail(status, raw, what)
        try:
            return json.loads(raw) if raw else {}
        except ValueError:
            raise RobloxError("Roblox sent something unreadable for %s." % what, status)

    def profile(self, user_id):
        """{"name", "displayName", "description"} as Roblox shows it publicly."""
        data = self._json("GET", ENDPOINTS["user"].format(user_id=int(user_id)), None, "the profile request")
        return {"name": str(data.get("name", "")), "displayName": str(data.get("displayName", "")),
                "description": str(data.get("description") or "")}

    def set_display_name(self, user_id, name):
        name = str(name or "").strip()
        if not name:
            raise RobloxError("Type a display name first.")
        self._json("PATCH", ENDPOINTS["display_name"].format(user_id=int(user_id)), {"newDisplayName": name},
                   "the display name change")

    def set_description(self, text):
        data = self._json("POST", ENDPOINTS["description"], {"description": str(text or "")[:1000]},
                          "the About change")
        return str(data.get("description", text) if isinstance(data, dict) else text)

    def privacy_settings(self):
        """Settings as Roblox describes them: [{"key", "label", "current", "options": [(value, label)]}]."""
        try:
            data = self._json("GET", ENDPOINTS["settings_options"], None, "the privacy settings request")
            parsed = parse_user_settings(data)
            if parsed:
                return parsed
        except RobloxError as e:
            if e.status in (401,):
                raise
        data = self._json("GET", ENDPOINTS["settings"], None, "the privacy settings request")
        return parse_user_settings(data)

    def update_privacy(self, changes):
        if not changes:
            return
        self._json("POST", ENDPOINTS["settings"], dict(changes), "the privacy change")

    def logout_everywhere(self):
        """Signs this account out on every device and returns the fresh cookie Roblox sends
        for this session (None if Roblox did not send one: the old login is then dead)."""
        status, headers, raw = self._request("POST", ENDPOINTS["logout_all"], body={}, extra=WEB_HEADERS)
        if status != 200:
            self._fail(status, raw, "sign out everywhere")
        fresh = cookie_from_headers(headers)
        if fresh:
            self._cookie = fresh
        return fresh


def cookie_from_headers(headers):
    if headers is None:
        return None
    try:
        values = headers.get_all("Set-Cookie") or []
    except AttributeError:
        values = [headers.get("Set-Cookie")] if headers.get("Set-Cookie") else []
    for v in values:
        for piece in str(v).split(";"):
            piece = piece.strip()
            if piece.startswith(".ROBLOSECURITY="):
                value = piece[len(".ROBLOSECURITY="):]
                if value:
                    return value
    return None


def _label(text):
    text = str(text)
    out = []
    for i, ch in enumerate(text):
        if ch.isupper() and i and not text[i - 1].isupper():
            out.append(" ")
        out.append(ch)
    return "".join(out).strip().capitalize()


def parse_user_settings(data):
    """Tolerant reader: works with {key: {currentValue, options: [...]}} as well as a flat
    {key: value} map (then each setting has only its current value as an option)."""
    if isinstance(data, dict) and isinstance(data.get("settings"), (dict, list)):
        data = data["settings"]
    items = []
    if isinstance(data, list):
        for d in data:
            if isinstance(d, dict) and isinstance(d.get("key") or d.get("name"), str):
                items.append((d.get("key") or d.get("name"), d))
    elif isinstance(data, dict):
        items = list(data.items())
    out = []
    for key, val in items[:80]:
        if not isinstance(key, str):
            continue
        if isinstance(val, dict):
            current = next((val[k] for k in ("currentValue", "value", "current") if k in val), None)
            options = []
            for o in val.get("options") or val.get("availableOptions") or []:
                if isinstance(o, dict):
                    v = next((o[k] for k in ("optionValue", "value", "key", "name") if k in o), None)
                    lab = next((o[k] for k in ("label", "displayText", "title", "text") if k in o), None)
                    if isinstance(v, (str, int, bool)):
                        options.append((v, str(lab) if lab else _label(v)))
                elif isinstance(o, (str, int, bool)):
                    options.append((o, _label(o)))
            label = next((val[k] for k in ("label", "title", "displayText") if isinstance(val.get(k), str)), None)
        elif isinstance(val, (str, int, bool)):
            current, options, label = val, [], None
        else:
            continue
        if not isinstance(current, (str, int, bool)) and not options:
            continue
        if isinstance(current, (str, int, bool)) and current not in [o[0] for o in options]:
            options.insert(0, (current, _label(current)))
        out.append({"key": key, "label": label or _label(key), "current": current, "options": options})
    return out


def headshot_url(user_id, opener=None, timeout=15):
    """The avatar headshot image URL (asks Roblox without any login)."""
    opener = opener or _default_opener
    request = urllib.request.Request(ENDPOINTS["headshot"].format(user_id=int(user_id)),
                                     headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    try:
        with opener(request, timeout) as response:
            data = json.loads(response.read())
    except Exception as e:
        raise RobloxError("Could not get the avatar picture (%s)." % e)
    for entry in (data.get("data") or []) if isinstance(data, dict) else []:
        url = str(entry.get("imageUrl") or "")
        host = urllib.parse.urlparse(url).hostname or ""
        if url.startswith("https://") and (host.endswith(".rbxcdn.com") or host.endswith(".roblox.com")):
            return url
    return None


def fetch_image(url, opener=None, timeout=15, limit=2 * 1024 * 1024):
    """Downloads a picture (no login sent)."""
    opener = opener or _default_opener
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with opener(request, timeout) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise RobloxError("The picture is larger than expected.")
    return data

