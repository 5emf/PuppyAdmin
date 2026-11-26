"""Posts Puppy Admin / Puppy Companion update announcements to a Discord channel through a
webhook (no bot to host). Standard library only.

  Automatic (GitHub Actions, .github/workflows/announce.yml, on every push):
      python tools/announce.py --push BEFORE_SHA AFTER_SHA
    posts only when PuppyAdmin.lua's SCRIPT_BUILD or the companion's PAYLOAD_VERSION changed,
    with the commit subjects in between as the "what's new" list.
  By hand (the workflow's "Run workflow" button, or your own PC):
      python tools/announce.py --title "Big update" --message "Line one\\nLine two" [--ping here]

The webhook URL comes from the DISCORD_WEBHOOK_URL environment variable (a GitHub secret);
it is never written to the repository or printed. --dry-run prints the message instead.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = "5emf/PuppyAdmin"
BRANCH = "ccr-3b4dfcff-nyfy0w"
SCRIPT_FILE = "PuppyAdmin.lua"
PAYLOAD_FILE = "companion/puppy_companion/_payload.py"
LOADSTRING = ('local H=game:GetService("HttpService") local ok,sha=pcall(function() return H:JSONDecode(game:HttpGet('
              '"https://api.github.com/repos/%s/commits/%s")).sha end) loadstring(game:HttpGet('
              '"https://raw.githubusercontent.com/%s/"..(ok and sha or "%s").."/PuppyAdmin.lua"))()') % (REPO, BRANCH, REPO, BRANCH)
COLOR_SCRIPT = 0xF59B28     # orange
COLOR_COMPANION = 0x5AA9FF  # blue
COLOR_NOTE = 0x9B9CA8
# Discord limits
MAX_DESC, MAX_FIELD, MAX_TITLE, MAX_EMBEDS = 4096, 1024, 256, 10
PINGS = {"none": None, "here": "@here", "everyone": "@everyone"}


# ------------------------------------------------------------------ pure helpers (tested)
def script_build(text):
    m = re.search(r'local\s+SCRIPT_BUILD\s*=\s*"([^"]+)"', text or "")
    return m.group(1) if m else None


def payload_version(text):
    m = re.search(r'PAYLOAD_VERSION\s*=\s*"([^"]+)"', text or "")
    return m.group(1) if m else None


def clean_subject(line):
    """A commit subject for a changelog: no trailing period, no co-author / session noise."""
    s = (line or "").strip()
    if not s or s.lower().startswith(("co-authored-by", "claude-session", "merge ")):
        return ""
    return s.rstrip(".")


def bullets(subjects, limit):
    """'- a\\n- b' within `limit` characters; the rest becomes '... and N more'."""
    out, used = [], 0
    subjects = [s for s in (clean_subject(x) for x in subjects) if s]
    for i, s in enumerate(subjects):
        line = "- " + (s if len(s) <= 300 else s[:297] + "...")
        rest = len(subjects) - i
        tail = len("\n... and %d more" % rest)
        if used + len(line) + 1 + tail > limit and out:
            out.append("... and %d more" % rest)
            break
        out.append(line)
        used += len(line) + 1
    return "\n".join(out)


def update_embeds(old_build, new_build, old_ver, new_ver, subjects, compare_url=None):
    """Embeds for a push: one per product that changed (script / companion). [] = nothing to announce."""
    embeds = []
    changes = bullets(subjects, MAX_DESC - 200) or "- Small fixes"
    if new_build and new_build != old_build:
        e = {"title": ("Puppy Admin updated - build %s" % new_build)[:MAX_TITLE], "color": COLOR_SCRIPT,
             "description": changes,
             "fields": [{"name": "Get it", "value": "Execute Puppy Admin again (a newer build replaces the running one):\n```lua\n%s\n```" % LOADSTRING}]}
        if old_build:
            e["footer"] = {"text": "was build %s" % old_build}
        embeds.append(e)
    if new_ver and new_ver != old_ver:
        e = {"title": ("Puppy Companion updated - %s" % new_ver)[:MAX_TITLE], "color": COLOR_COMPANION,
             "description": changes if not embeds else "See the list above.",
             "fields": [{"name": "Get it", "value": "Restart Puppy Companion: it downloads the update itself."}]}
        if old_ver:
            e["footer"] = {"text": "was %s" % old_ver}
        embeds.append(e)
    if compare_url and embeds:
        embeds[-1]["url"] = compare_url
    for e in embeds:
        for f in e.get("fields", []):
            f["value"] = f["value"][:MAX_FIELD]
    return embeds[:MAX_EMBEDS]


def manual_embed(title, message):
    text = (message or "").replace("\\n", "\n").strip()
    return {"title": (title or "Puppy Admin")[:MAX_TITLE], "color": COLOR_NOTE, "description": text[:MAX_DESC] or "-"}


def payload(embeds, ping=None, username="Puppy Admin updates"):
    """The webhook body. Mentions are only allowed for the ping that was asked for."""
    body = {"username": username, "embeds": embeds, "allowed_mentions": {"parse": []}}
    mention = PINGS.get(ping or "none")
    if ping and ping.startswith("role:"):
        rid = ping[5:]
        if rid.isdigit():
            mention = "<@&%s>" % rid
            body["allowed_mentions"] = {"roles": [rid]}
    elif mention:
        body["allowed_mentions"] = {"parse": ["everyone"]}
    if mention:
        body["content"] = mention
    return body


# ------------------------------------------------------------------ git + network
def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout


def file_at(rev, path):
    if not rev or set(rev) == {"0"}:
        return ""
    return git("show", "%s:%s" % (rev, path))


def subjects_between(before, after):
    if not before or set(before) == {"0"}:
        return git("log", "-1", "--format=%s", after).splitlines()
    return git("log", "--reverse", "--format=%s", "%s..%s" % (before, after)).splitlines()


def post(url, body, tries=3):
    data = json.dumps(body).encode("utf-8")
    for attempt in range(tries):
        req = urllib.request.Request(url + ("&" if "?" in url else "?") + "wait=true", data=data,
                                     headers={"Content-Type": "application/json", "User-Agent": "PuppyAdminAnnouncer/1"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < tries - 1:
                try:
                    wait = float(json.loads(e.read().decode()).get("retry_after", 2))
                except (ValueError, AttributeError):
                    wait = 2
                time.sleep(min(wait, 30))
                continue
            raise SystemExit("Discord refused the message (HTTP %d)" % e.code)
    raise SystemExit("Discord kept rate-limiting the message")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--push", nargs=2, metavar=("BEFORE", "AFTER"), help="announce what changed between two commits")
    ap.add_argument("--title", help="manual announcement title")
    ap.add_argument("--message", help="manual announcement text (\\n for new lines)")
    ap.add_argument("--ping", default="none", help="none, here, everyone or role:<role id>")
    ap.add_argument("--dry-run", action="store_true", help="print instead of posting")
    a = ap.parse_args(argv)

    if a.push:
        before, after = a.push
        embeds = update_embeds(script_build(file_at(before, SCRIPT_FILE)), script_build(file_at(after, SCRIPT_FILE)),
                               payload_version(file_at(before, PAYLOAD_FILE)), payload_version(file_at(after, PAYLOAD_FILE)),
                               subjects_between(before, after),
                               "https://github.com/%s/compare/%s...%s" % (REPO, before[:12], after[:12])
                               if before and set(before) != {"0"} else None)
        if not embeds:
            print("No new build or companion version in this push: nothing to announce.")
            return 0
    elif a.message or a.title:
        embeds = [manual_embed(a.title, a.message)]
    else:
        ap.error("give --push BEFORE AFTER, or --title / --message")

    body = payload(embeds, a.ping)
    if a.dry_run:
        print(json.dumps(body, indent=2))
        return 0
    url = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not url.startswith("https://discord.com/api/webhooks/") and not url.startswith("https://discordapp.com/api/webhooks/"):
        print("DISCORD_WEBHOOK_URL is not set (or is not a Discord webhook URL): nothing posted.")
        return 0
    status = post(url, body)
    print("Posted to Discord (HTTP %s): %s" % (status, ", ".join(e["title"] for e in embeds)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
