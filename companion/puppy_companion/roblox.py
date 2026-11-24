"""The few Roblox web calls the companion needs. The cookie only ever goes to roblox.com."""
import json
import urllib.error
import urllib.request

USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PuppyCompanion/1.0"
AUTH_URL = "https://users.roblox.com/v1/users/authenticated"
TICKET_URL = "https://auth.roblox.com/v1/authentication-ticket/"
PRESENCE_URL = "https://presence.roblox.com/v1/presence/users"


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
