// Pupdates relay: a Cloudflare Worker between the Pupdates apps and your Discord channel.
//
// It keeps the Discord webhook secret (people never see it) and only accepts posts from people
// on your whitelist, each with their own access key. You add and remove people from the Pupdates
// desktop app (Whitelist section) with your admin key.
//
// Settings (Cloudflare dashboard > Workers > your worker > Settings):
//   secret DISCORD_WEBHOOK_URL  the channel's webhook URL
//   secret ADMIN_KEY            a long random password only you know (manages the whitelist)
//   KV binding PUPDATES         a KV namespace (stores the whitelist; keys are stored hashed)
//
// API (all JSON answers):
//   GET    /me                      Authorization: Bearer <access key>  -> { name, canPing }
//   POST   /post                    Authorization: Bearer <access key>, multipart form:
//                                     payload = JSON { title, message, color, ping, roleId, embed, loadstring, username, avatarUrl }
//                                     image   = optional picture (png / jpg / gif / webp, up to 8 MB)
//   GET    /admin/users             X-Admin-Key: <admin key>   -> [ { name, canPing, added } ]
//   POST   /admin/users             X-Admin-Key, JSON { name, canPing } -> { name, key }  (the key is shown once)
//   DELETE /admin/users/<name>      X-Admin-Key               -> { ok: true }
//   POST   /admin/avatar            X-Admin-Key, JSON { avatar: "data:image/png;base64,..." | null, name? }
//                                     -> changes the webhook's own picture (and name) for good

export const LOADSTRING = 'local H=game:GetService("HttpService") local ok,sha=pcall(function() return H:JSONDecode(game:HttpGet("https://api.github.com/repos/5emf/PuppyAdmin/commits/ccr-3b4dfcff-nyfy0w")).sha end) loadstring(game:HttpGet("https://raw.githubusercontent.com/5emf/PuppyAdmin/"..(ok and sha or "ccr-3b4dfcff-nyfy0w").."/PuppyAdmin.lua"))()';
export const MAX_IMAGE = 8 * 1024 * 1024;
export const RATE_PER_MINUTE = 10;
const IMAGE_TYPES = { "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp" };

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
}

export async function sha256(text) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function newKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return "pup_" + btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// constant-time comparison for the admin key
export function sameSecret(a, b) {
  a = String(a || ""); b = String(b || "");
  if (!a || !b) return false;
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}

export function cleanName(name) {
  const n = String(name || "").trim().replace(/\s+/g, " ");
  return /^[\w .'-]{1,32}$/.test(n) ? n : null;
}

// The Discord message for a whitelisted person's post. Pings only for people allowed to ping.
export function discordPayload(p, user, fileName) {
  const by = `Posted by ${user.name} via Pupdates`;
  const body = { username: String(p.username || "Pupdates").slice(0, 80), allowed_mentions: { parse: [] } };
  const avatar = String(p.avatarUrl || "").trim();
  if (/^https:\/\/\S+$/.test(avatar) && avatar.length <= 2000) body.avatar_url = avatar;
  let mention = "";
  if (user.canPing) {
    if (p.ping === "@here" || p.ping === "@everyone") { mention = p.ping; body.allowed_mentions = { parse: ["everyone"] }; }
    else if (p.ping === "role" && /^\d+$/.test(String(p.roleId || ""))) { mention = `<@&${p.roleId}>`; body.allowed_mentions = { roles: [String(p.roleId)] }; }
  }
  const message = String(p.message || "").trim();
  if (p.embed === false) {
    let text = [mention, message].filter(Boolean).join("\n");
    if (p.loadstring) text += "\n```lua\n" + LOADSTRING + "\n```";
    text += `\n-# ${by}`;
    body.content = text.slice(0, 2000);
  } else {
    const embed = { title: String(p.title || "Pupdates").slice(0, 256), description: message.slice(0, 4096) || "-",
      color: Number.isInteger(p.color) ? p.color : 0xF59B28, footer: { text: by } };
    if (p.loadstring) embed.fields = [{ name: "Loadstring", value: ("```lua\n" + LOADSTRING + "\n```").slice(0, 1024) }];
    if (fileName) embed.image = { url: `attachment://${fileName}` };
    body.embeds = [embed];
    if (mention) body.content = mention;
  }
  return body;
}

async function userFor(request, env) {
  const auth = request.headers.get("authorization") || "";
  const m = auth.match(/^Bearer\s+(\S+)$/i);
  if (!m) return null;
  const raw = await env.PUPDATES.get("user:" + (await sha256(m[1])));
  return raw ? JSON.parse(raw) : null;
}

async function rateLimited(env, user) {
  const key = "rate:" + user.name + ":" + Math.floor(Date.now() / 60000);
  const n = parseInt((await env.PUPDATES.get(key)) || "0", 10);
  if (n >= RATE_PER_MINUTE) return true;
  await env.PUPDATES.put(key, String(n + 1), { expirationTtl: 120 });
  return false;
}

async function handlePost(request, env) {
  const user = await userFor(request, env);
  if (!user) return json({ error: "Not on the whitelist (wrong or removed access key)" }, 401);
  if (await rateLimited(env, user)) return json({ error: `Slow down: ${RATE_PER_MINUTE} posts a minute at most` }, 429);
  let form;
  try { form = await request.formData(); } catch { return json({ error: "Send the post as a form (payload + optional image)" }, 400); }
  let p;
  try { p = JSON.parse(form.get("payload") || "{}"); } catch { return json({ error: "The payload is not JSON" }, 400); }
  if (!String(p.message || "").trim() && !String(p.title || "").trim() && !form.get("image")) {
    return json({ error: "Write something or add a picture" }, 400);
  }
  const out = new FormData();
  let fileName = null;
  const image = form.get("image");
  if (image && typeof image === "object" && image.size) {
    const ext = IMAGE_TYPES[image.type];
    if (!ext) return json({ error: "Pictures must be PNG, JPG, GIF or WEBP" }, 400);
    if (image.size > MAX_IMAGE) return json({ error: "The picture is bigger than 8 MB" }, 400);
    fileName = "pupdates." + ext;
    out.append("files[0]", new Blob([await image.arrayBuffer()], { type: image.type }), fileName);
  }
  out.append("payload_json", JSON.stringify(discordPayload(p, user, fileName)));
  const res = await fetch(env.DISCORD_WEBHOOK_URL + "?wait=true", { method: "POST", body: out });
  if (!res.ok) return json({ error: `Discord refused the post (HTTP ${res.status})` }, 502);
  const msg = await res.json().catch(() => ({}));
  return json({ ok: true, id: msg.id || "", pingDropped: Boolean(p.ping && p.ping !== "none" && !user.canPing) });
}

async function handleAdmin(request, env, path) {
  if (!sameSecret(request.headers.get("x-admin-key"), env.ADMIN_KEY)) return json({ error: "Wrong admin key" }, 401);
  const index = JSON.parse((await env.PUPDATES.get("index")) || "{}"); // name -> { hash, canPing, added }
  if (path === "/admin/users" && request.method === "GET") {
    return json(Object.entries(index).map(([name, u]) => ({ name, canPing: !!u.canPing, added: u.added })));
  }
  if (path === "/admin/users" && request.method === "POST") {
    const body = await request.json().catch(() => ({}));
    const name = cleanName(body.name);
    if (!name) return json({ error: "Names are 1-32 letters, numbers, spaces, . ' - or _" }, 400);
    if (index[name]) await env.PUPDATES.delete("user:" + index[name].hash); // a new key replaces the old one
    const key = newKey();
    const hash = await sha256(key);
    const rec = { name, canPing: !!body.canPing, added: new Date().toISOString() };
    await env.PUPDATES.put("user:" + hash, JSON.stringify(rec));
    index[name] = { hash, canPing: rec.canPing, added: rec.added };
    await env.PUPDATES.put("index", JSON.stringify(index));
    return json({ name, key, canPing: rec.canPing });
  }
  if (path === "/admin/avatar" && request.method === "POST") {
    const body = await request.json().catch(() => null);
    if (!body || !(body.avatar === null || /^data:image\/(png|jpeg|gif);base64,[A-Za-z0-9+/=]+$/.test(String(body.avatar || "")))) {
      return json({ error: "Send { avatar: a PNG / JPG / GIF data URI, or null }" }, 400);
    }
    const patch = { avatar: body.avatar };
    if (body.name) patch.name = String(body.name).slice(0, 80);
    const res = await fetch(env.DISCORD_WEBHOOK_URL, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify(patch) });
    if (!res.ok) return json({ error: `Discord did not change the picture (HTTP ${res.status})` }, 502);
    return json({ ok: true });
  }
  const del = path.match(/^\/admin\/users\/(.+)$/);
  if (del && request.method === "DELETE") {
    const name = decodeURIComponent(del[1]);
    if (!index[name]) return json({ error: "No one called " + name }, 404);
    await env.PUPDATES.delete("user:" + index[name].hash);
    delete index[name];
    await env.PUPDATES.put("index", JSON.stringify(index));
    return json({ ok: true });
  }
  return json({ error: "Unknown admin request" }, 404);
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname.replace(/\/+$/, "") || "/";
    if (!env.DISCORD_WEBHOOK_URL || !env.ADMIN_KEY || !env.PUPDATES) {
      return json({ error: "The relay is not set up (DISCORD_WEBHOOK_URL, ADMIN_KEY and the PUPDATES KV binding)" }, 500);
    }
    try {
      if (path === "/me" && request.method === "GET") {
        const user = await userFor(request, env);
        return user ? json({ name: user.name, canPing: !!user.canPing }) : json({ error: "Not on the whitelist" }, 401);
      }
      if (path === "/post" && request.method === "POST") return await handlePost(request, env);
      if (path.startsWith("/admin/")) return await handleAdmin(request, env, path);
      if (path === "/") return json({ name: "Pupdates relay", ok: true });
      return json({ error: "Not found" }, 404);
    } catch (e) {
      return json({ error: "Relay error: " + (e && e.message ? e.message : String(e)) }, 500);
    }
  },
};
