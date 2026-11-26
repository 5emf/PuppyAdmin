// Pupdates relay tests: node --test pupdates/relay/test/
import test from "node:test";
import assert from "node:assert/strict";
import worker, { discordPayload, sameSecret, cleanName, sha256 } from "../worker.js";

class KV {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v) { this.m.set(k, v); }
  async delete(k) { this.m.delete(k); }
}

function setup() {
  const sent = [];
  globalThis.fetch = async (url, init) => {
    sent.push({ url, form: init.body });
    return new Response(JSON.stringify({ id: "42" }), { status: 200 });
  };
  const env = { DISCORD_WEBHOOK_URL: "https://discord.com/api/webhooks/1/secret", ADMIN_KEY: "admin-pass", PUPDATES: new KV() };
  return { env, sent };
}
const call = (env, path, init = {}) => worker.fetch(new Request("https://relay.example" + path, init), env);
const admin = (env, path, init = {}) => call(env, path, { ...init, headers: { ...(init.headers || {}), "x-admin-key": "admin-pass" } });

test("helpers", async () => {
  assert.ok(sameSecret("abc", "abc") && !sameSecret("abc", "abd") && !sameSecret("", "") && !sameSecret("a", "ab"));
  assert.equal(cleanName("  Pup  Alt "), "Pup Alt");
  assert.equal(cleanName("<script>"), null);
  assert.equal((await sha256("x")).length, 64);
  const p = discordPayload({ title: "T", message: "M", ping: "@everyone" }, { name: "Bob", canPing: false }, "pupdates.png");
  assert.equal(p.content, undefined, "no ping for someone not allowed to ping");
  assert.deepEqual(p.allowed_mentions, { parse: [] });
  assert.equal(p.embeds[0].image.url, "attachment://pupdates.png");
  assert.match(p.embeds[0].footer.text, /Posted by Bob/);
  const plain = discordPayload({ message: "hi", embed: false, ping: "@here" }, { name: "Owner", canPing: true });
  assert.ok(plain.content.startsWith("@here\nhi") && plain.content.includes("-# Posted by Owner"));
});

test("whitelist: add, post, remove", async () => {
  const { env, sent } = setup();
  assert.equal((await call(env, "/admin/users")).status, 401, "admin needs the admin key");
  const add = await (await admin(env, "/admin/users", { method: "POST", body: JSON.stringify({ name: "Alt Pup" }) })).json();
  assert.ok(add.key.startsWith("pup_"));
  assert.ok(![...env.PUPDATES.m.values()].some((v) => v.includes(add.key)), "keys are stored hashed");
  const list = await (await admin(env, "/admin/users")).json();
  assert.deepEqual(list.map((u) => u.name), ["Alt Pup"]);
  const me = await (await call(env, "/me", { headers: { authorization: "Bearer " + add.key } })).json();
  assert.equal(me.name, "Alt Pup");

  const form = new FormData();
  form.append("payload", JSON.stringify({ title: "Hello", message: "World", ping: "@everyone" }));
  form.append("image", new Blob([new Uint8Array([137, 80, 78, 71])], { type: "image/png" }), "cat.png");
  const res = await call(env, "/post", { method: "POST", body: form, headers: { authorization: "Bearer " + add.key } });
  const out = await res.json();
  assert.equal(res.status, 200);
  assert.equal(out.id, "42");
  assert.equal(out.pingDropped, true);
  assert.equal(sent[0].url, "https://discord.com/api/webhooks/1/secret?wait=true");
  const payload = JSON.parse(sent[0].form.get("payload_json"));
  assert.equal(payload.embeds[0].title, "Hello");
  assert.ok(sent[0].form.get("files[0]"), "the picture is forwarded");

  assert.equal((await call(env, "/post", { method: "POST", body: form, headers: { authorization: "Bearer nope" } })).status, 401);
  await admin(env, "/admin/users/" + encodeURIComponent("Alt Pup"), { method: "DELETE" });
  assert.equal((await call(env, "/me", { headers: { authorization: "Bearer " + add.key } })).status, 401, "removed: the key stops working");
});

test("limits", async () => {
  const { env } = setup();
  const add = await (await admin(env, "/admin/users", { method: "POST", body: JSON.stringify({ name: "Spammer" }) })).json();
  const send = (extra) => {
    const f = new FormData();
    f.append("payload", JSON.stringify({ message: "x" }));
    if (extra) f.append("image", extra, "f.bin");
    return call(env, "/post", { method: "POST", body: f, headers: { authorization: "Bearer " + add.key } });
  };
  assert.equal((await send(new Blob(["x"], { type: "text/plain" }))).status, 400, "only pictures");
  let last;
  for (let i = 0; i < 11; i++) last = await send();
  assert.equal(last.status, 429, "rate limited after 10 a minute");
  const bad = await admin(env, "/admin/users", { method: "POST", body: JSON.stringify({ name: "" }) });
  assert.equal(bad.status, 400);
});
