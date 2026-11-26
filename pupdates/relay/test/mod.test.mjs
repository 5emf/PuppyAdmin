// Moderation + staff tests: node --test pupdates/relay/test/mod.test.mjs
import test from "node:test";
import assert from "node:assert/strict";
import worker from "../worker.js";
import { COMMANDS, handleInteraction, levelOf, verifySignature, appIdFromToken, snowflakeTime, minutesText, installCommands } from "../mod.js";

class KV {
  constructor() { this.m = new Map(); }
  async get(k) { return this.m.has(k) ? this.m.get(k) : null; }
  async put(k, v) { this.m.set(k, v); }
  async delete(k) { this.m.delete(k); }
}

const GUILD = "500000000000000001", APP = "123456789012345678", OWNER = "600000000000000001";
const ADMINP = String(1n << 3n);
const TOKEN = ["MTIzNDU2Nzg5MDEyMzQ1Njc4", "Ga" + "BcDe", "abcdefghijklmnop" + "qrstuvwxyz012345"].join(".");

// a fake Discord: records calls, answers like the API
function fakeDiscord(opts = {}) {
  const calls = [];
  const fetcher = async (url, init) => {
    const path = url.replace("https://discord.com/api/v10", "");
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ method: init.method, path, body, reason: init.headers["x-audit-log-reason"] });
    const ok = (data) => (data === undefined ? new Response(null, { status: 204 }) : new Response(JSON.stringify(data), { status: 200 }));
    if (opts.deny && opts.deny.test(path)) return new Response(JSON.stringify({ message: "Missing Permissions", code: 50013 }), { status: 403 });
    if (path === `/guilds/${GUILD}`) return ok({ id: GUILD, name: "Pup Town", owner_id: OWNER });
    if (path === "/users/@me/channels") return ok({ id: "dm1" });
    if (path.startsWith(`/channels/c1/messages?`)) {
      const now = BigInt(Date.now() - 1420070400000) << 22n;
      const old = BigInt(Date.now() - 20 * 86400000 - 1420070400000) << 22n;
      return ok([
        { id: String(now + 3n), author: { id: "u1" } }, { id: String(now + 2n), author: { id: "u2" } },
        { id: String(now + 1n), author: { id: "u1" } }, { id: String(old), author: { id: "u1" } }]);
    }
    if (path === "/channels/c1" && init.method === "GET") return ok({ id: "c1", permission_overwrites: [{ id: GUILD, type: 0, allow: "1024", deny: "0" }] });
    if (path === `/applications/${APP}/commands`) return ok(body.map((c, n) => ({ ...c, id: String(n) })));
    if (init.method === "DELETE" || init.method === "PUT") return ok(undefined);
    return ok({ id: "m1" });
  };
  return { calls, fetcher };
}

function env(extra = {}) {
  return { DISCORD_BOT_TOKEN: TOKEN, PUPDATES: new KV(), ...extra };
}

const member = (id, { roles = [], perms = "0", name = "user" + id } = {}) => ({ user: { id, username: name }, roles, permissions: perms });

function slash(name, opts, actor, { sub, resolved = {}, channel = "c1" } = {}) {
  let options = Object.entries(opts).map(([k, v]) => ({ name: k, value: v }));
  if (sub) options = [{ type: 1, name: sub, options }];
  return { type: 2, id: "i1", token: "tok", application_id: APP, guild_id: GUILD, channel_id: channel, member: actor,
           data: { name, options, resolved } };
}
const target = (id, roles = [], perms = "0") => ({ users: { [id]: { id, username: "t" + id } }, members: { [id]: { roles, permissions: perms } } });

async function run(e, d, i) {
  const pending = [];
  const answer = await handleInteraction(i, e, (p) => pending.push(p), d.fetcher);
  await Promise.all(pending);
  const edit = d.calls.filter((c) => c.path === `/webhooks/${APP}/tok/messages/@original`).pop();
  return { answer, text: answer.type === 4 ? answer.data.content : edit && edit.body.content };
}

test("signature check (Ed25519, as Discord signs)", async () => {
  const keys = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const pub = Buffer.from(await crypto.subtle.exportKey("raw", keys.publicKey)).toString("hex");
  const ts = String(Math.floor(Date.now() / 1000));
  const body = JSON.stringify({ type: 1 });
  const sig = Buffer.from(await crypto.subtle.sign({ name: "Ed25519" }, keys.privateKey, new TextEncoder().encode(ts + body))).toString("hex");
  assert.equal(await verifySignature(pub, sig, ts, body), true);
  assert.equal(await verifySignature(pub, sig, ts, body + " "), false, "a changed body fails");
  assert.equal(await verifySignature(pub, sig, String(Number(ts) - 3600), body), false, "an old request fails");
  assert.equal(await verifySignature("zz", sig, ts, body), false);

  // through the worker: PING -> PONG, unsigned -> 401
  const e = env({ DISCORD_PUBLIC_KEY: pub });
  const signed = (b) => new Request("https://relay.example/interactions", { method: "POST", body: b,
    headers: { "x-signature-ed25519": sig, "x-signature-timestamp": ts } });
  const res = await worker.fetch(signed(body), e, { waitUntil() {} });
  assert.deepEqual(await res.json(), { type: 1 });
  const bad = await worker.fetch(new Request("https://relay.example/interactions", { method: "POST", body }), e, {});
  assert.equal(bad.status, 401);
});

test("helpers", () => {
  assert.equal(appIdFromToken(TOKEN), APP);
  assert.equal(minutesText(60), "1 hour");
  assert.equal(minutesText(2880), "2 days");
  assert.equal(minutesText(5), "5 minutes");
  assert.ok(Math.abs(snowflakeTime(String(BigInt(Date.now() - 1420070400000) << 22n)) - Date.now()) < 5);
  for (const c of COMMANDS) {
    assert.ok(/^[a-z_]{1,32}$/.test(c.name) && c.description.length <= 100, c.name);
    for (const o of c.options || []) {
      assert.ok(/^[a-z_]{1,32}$/.test(o.name) && o.description.length <= 100, `${c.name} ${o.name}`);
      for (const p of o.options || []) assert.ok(p.description.length <= 100, `${c.name} ${o.name} ${p.name}`);
    }
  }
});

test("levels: owner, Administrator, staff users and roles", () => {
  const cfg = { owner: OWNER, staff: { users: { "7": 2 }, roles: { r1: 1, r3: 3 } } };
  assert.equal(levelOf(OWNER, member(OWNER), cfg, {}), 4);
  assert.equal(levelOf("9", member("9"), cfg, { OWNER_IDS: "8, 9" }), 4);
  assert.equal(levelOf("5", member("5", { perms: ADMINP }), cfg, {}), 3);
  assert.equal(levelOf("7", member("7"), cfg, {}), 2);
  assert.equal(levelOf("6", member("6", { roles: ["r1"] }), cfg, {}), 1);
  assert.equal(levelOf("6", member("6", { roles: ["r1", "r3"] }), cfg, {}), 3);
  assert.equal(levelOf("4", member("4"), cfg, {}), 0);
});

test("staff: owner adds an admin, the admin adds a helper, members are refused", async () => {
  const e = env(), d = fakeDiscord();
  const owner = member(OWNER);
  let r = await run(e, d, slash("staff", { user: "700", level: 3 }, owner, { sub: "add", resolved: target("700") }));
  assert.match(r.text, /is now \*\*admin\*\*/);
  const admin = member("700");
  r = await run(e, d, slash("staff", { user: "701", level: 1 }, admin, { sub: "add", resolved: target("701") }));
  assert.match(r.text, /is now \*\*helper\*\*/);
  r = await run(e, d, slash("staff", { user: "702", level: 3 }, admin, { sub: "add", resolved: target("702") }));
  assert.match(r.text, /only give levels below your own/);
  r = await run(e, d, slash("staff", { role: "r9", level: 2 }, admin, { sub: "role", resolved: {} }));
  assert.match(r.text, /<@&r9> is now \*\*moderator\*\*/);
  r = await run(e, d, slash("warn", { user: "701", reason: "x" }, member("800"), { resolved: target("701") }));
  assert.match(r.text, /need to be \*\*helper\*\*/);
  assert.equal(r.answer.data.flags, 64, "refusals are private");
  r = await run(e, d, slash("staff", {}, member("701"), { sub: "list" }));
  assert.match(r.text, /\*\*admin\*\*: <@700>/);
  assert.match(r.text, /\*\*moderator\*\*: <@&r9> \(role\)/);
  assert.match(r.text, /\*\*helper\*\*: <@701>/);
  r = await run(e, d, slash("staff", { user: "700" }, member("701"), { sub: "remove", resolved: target("700") }));
  assert.match(r.text, /need to be \*\*admin\*\*/);
  r = await run(e, d, slash("staff", { user: "701" }, admin, { sub: "remove", resolved: target("701") }));
  assert.match(r.text, /no longer on the staff list/);
});

test("warn, warnings, clearwarn, case: cases, DM, log and notice", async () => {
  const e = env(), d = fakeDiscord();
  const owner = member(OWNER);
  await run(e, d, slash("modsettings", { log_channel: "log1" }, owner));
  await run(e, d, slash("staff", { user: "701", level: 1 }, owner, { sub: "add", resolved: target("701") }));
  const helper = member("701");
  let r = await run(e, d, slash("warn", { user: "900", reason: "spam" }, helper, { resolved: target("900") }));
  assert.equal(r.answer.type, 5, "deferred, then edited");
  assert.match(r.text, /Warned <@900> \(case #1, 1 warning now\)/);
  assert.ok(d.calls.some((c) => c.path === "/channels/dm1/messages" && c.body.content.includes("warned in **Pup Town**: spam")), "DM sent");
  assert.ok(d.calls.some((c) => c.path === "/channels/log1/messages" && c.body.embeds[0].author.name.startsWith("WARN")), "logged");
  assert.ok(d.calls.some((c) => c.path === "/channels/c1/messages" && c.body.content === "<@900> was warned: spam"), "public notice");
  await run(e, d, slash("warn", { user: "900", reason: "again" }, helper, { resolved: target("900") }));
  r = await run(e, d, slash("warnings", { user: "900" }, helper, { resolved: target("900") }));
  assert.match(r.text, /2 active warnings, 2 cases/);
  r = await run(e, d, slash("clearwarn", { user: "900", case: 1 }, helper, { resolved: target("900") }));
  assert.match(r.text, /need to be \*\*moderator\*\*/);
  r = await run(e, d, slash("clearwarn", { user: "900", case: 1 }, owner, { resolved: target("900") }));
  assert.match(r.text, /Cleared 1 warning of <@900> \(case #3\)/);
  r = await run(e, d, slash("warnings", { user: "900" }, helper, { resolved: target("900") }));
  assert.match(r.text, /1 active warning, 3 cases/);
  assert.match(r.text, /#1\*\* warn \(cleared\)/);
  r = await run(e, d, slash("case", { number: 2 }, helper));
  assert.match(r.text, /#2\*\* warn .*again/);
  r = await run(e, d, slash("note", { user: "900", text: "watch them" }, helper, { resolved: target("900") }));
  assert.match(r.text, /They were not told/);
  assert.ok(!d.calls.some((c) => c.path === "/channels/c1/messages" && /note/.test(c.body.content || "")), "notes are not announced");
});

test("timeout, kick, ban, unban call Discord with the audit reason; limits and hierarchy", async () => {
  const e = env(), d = fakeDiscord();
  const owner = member(OWNER);
  await run(e, d, slash("staff", { user: "701", level: 1 }, owner, { sub: "add", resolved: target("701") }));
  await run(e, d, slash("staff", { user: "702", level: 2 }, owner, { sub: "add", resolved: target("702") }));
  const helper = member("701"), mod = member("702");
  let r = await run(e, d, slash("timeout", { user: "900", minutes: 120 }, helper, { resolved: target("900") }));
  assert.match(r.text, /60 minutes at most/);
  r = await run(e, d, slash("timeout", { user: "900", minutes: 120, reason: "calm down" }, mod, { resolved: target("900") }));
  assert.match(r.text, /Timed out <@900> for 2 hours/);
  const t = d.calls.find((c) => c.method === "PATCH" && c.path === `/guilds/${GUILD}/members/900`);
  assert.ok(Math.abs(Date.parse(t.body.communication_disabled_until) - Date.now() - 7200000) < 5000);
  assert.equal(decodeURIComponent(t.reason), "@user702: calm down");
  r = await run(e, d, slash("timeout", { user: "702", minutes: 5 }, helper, { resolved: target("702") }));
  assert.match(r.text, /cannot do that to a moderator/);
  r = await run(e, d, slash("kick", { user: "701" }, mod, { resolved: target("701") }));
  assert.match(r.text, /Kicked <@701>/, "a moderator outranks a helper");
  const dmAt = d.calls.findIndex((c) => c.path === "/channels/dm1/messages" && /kicked/.test(c.body.content));
  const kickAt = d.calls.findIndex((c) => c.method === "DELETE" && c.path === `/guilds/${GUILD}/members/701`);
  assert.ok(dmAt >= 0 && dmAt < kickAt, "the DM goes out before the kick");
  r = await run(e, d, slash("ban", { user: "901" }, mod, { resolved: target("901") }));
  assert.match(r.text, /need to be \*\*admin\*\*/);
  r = await run(e, d, slash("ban", { user: "901", delete_messages: 86400, reason: "raid" }, owner, { resolved: { users: { "901": { id: "901", username: "raider" } } } }));
  assert.match(r.text, /Banned <@901>/);
  assert.deepEqual(d.calls.find((c) => c.method === "PUT" && c.path === `/guilds/${GUILD}/bans/901`).body, { delete_message_seconds: 86400 });
  r = await run(e, d, slash("unban", { user_id: "901901901901901901" }, owner));
  assert.match(r.text, /Unbanned/);
  r = await run(e, d, slash("kick", { user: OWNER }, member("5", { perms: ADMINP }), { resolved: target(OWNER) }));
  assert.match(r.text, /cannot do that to a owner/);
  r = await run(e, d, slash("warn", { user: APP, reason: "x" }, owner, { resolved: { users: { [APP]: { id: APP, username: "bot", bot: true } } } }));
  assert.match(r.text, /Not on bots/);
  r = await run(e, d, slash("warn", { user: OWNER, reason: "x" }, owner, { resolved: target(OWNER) }));
  assert.match(r.text, /Not on yourself/);
});

test("purge, lock, slowmode; Discord's refusals become readable text", async () => {
  const e = env(), d = fakeDiscord();
  const owner = member(OWNER);
  let r = await run(e, d, slash("purge", { count: 10, user: "u1" }, owner, { resolved: { users: { u1: { id: "u1", username: "u1" } } } }));
  assert.match(r.text, /Deleted 2 messages/, "only u1's, and not older than 14 days");
  assert.equal(d.calls.find((c) => c.path === "/channels/c1/messages/bulk-delete").body.messages.length, 2);
  r = await run(e, d, slash("lock", {}, owner));
  const put = d.calls.find((c) => c.method === "PUT" && c.path === `/channels/c1/permissions/${GUILD}`);
  assert.deepEqual(put.body, { type: 0, allow: "1024", deny: String(1n << 11n) }, "other permissions kept, Send Messages denied");
  r = await run(e, d, slash("slowmode", { seconds: 30 }, owner));
  assert.match(r.text, /30 s/);
  const d2 = fakeDiscord({ deny: /\/bans\// });
  r = await run(e, d2, slash("ban", { user: "901" }, owner, { resolved: target("901") }));
  assert.match(r.text, /Could not do it: The bot is missing a permission .*drag the bot's role up/);
});

test("install the commands", async () => {
  const d = fakeDiscord();
  const out = await installCommands(env(), "https://relay.example", d.fetcher);
  assert.equal(out.count, COMMANDS.length);
  assert.equal(out.interactionsUrl, "https://relay.example/interactions");
  assert.equal(d.calls[0].path, `/applications/${APP}/commands`);
  assert.equal(d.calls[0].method, "PUT");
});

test("automatic timeout at every N active warnings", async () => {
  const e = env(), d = fakeDiscord();
  const owner = member(OWNER);
  let r = await run(e, d, slash("modsettings", { auto_timeout_warns: 2, auto_timeout_minutes: 30 }, owner));
  assert.match(r.text, /automatic timeout: 30 minutes at every 2 warnings/);
  r = await run(e, d, slash("warn", { user: "900", reason: "one" }, owner, { resolved: target("900") }));
  assert.ok(!/automatically/.test(r.text));
  r = await run(e, d, slash("warn", { user: "900", reason: "two" }, owner, { resolved: target("900") }));
  assert.match(r.text, /2 warnings: timed out automatically for 30 minutes \(case #3\)/);
  const t = d.calls.filter((c) => c.method === "PATCH" && c.path === `/guilds/${GUILD}/members/900`);
  assert.equal(t.length, 1);
  assert.equal(decodeURIComponent(t[0].reason), "automatic: 2 warnings");
  r = await run(e, d, slash("warnings", { user: "900" }, owner, { resolved: target("900") }));
  assert.match(r.text, /timeout 30 minutes \(automatic\)/);
  assert.match(r.text, new RegExp(`by <@${APP}>`));
  // a warned user who left the server: no timeout, said so
  r = await run(e, d, slash("warn", { user: "901", reason: "a" }, owner, { resolved: { users: { "901": { id: "901", username: "gone" } } } }));
  r = await run(e, d, slash("warn", { user: "901", reason: "b" }, owner, { resolved: { users: { "901": { id: "901", username: "gone" } } } }));
  assert.match(r.text, /Not in the server, so no automatic timeout/);
  // turned off
  await run(e, d, slash("modsettings", { auto_timeout_warns: 0 }, owner));
  r = await run(e, d, slash("warn", { user: "900", reason: "three" }, owner, { resolved: target("900") }));
  r = await run(e, d, slash("warn", { user: "900", reason: "four" }, owner, { resolved: target("900") }));
  assert.ok(!/automatically/.test(r.text));
});

test("the apps' Moderation section: servers, cases, clear a warning", async () => {
  const e = env({ ADMIN_KEY: "admin-pass", DISCORD_CHANNEL_ID: "1" }), d = fakeDiscord();
  const owner = member(OWNER);
  for (let k = 0; k < 3; k++) await run(e, d, slash("warn", { user: "900", reason: "w" + k }, owner, { resolved: target("900") }));
  await run(e, d, slash("note", { user: "901", text: "n" }, owner, { resolved: target("901") }));
  globalThis.fetch = d.fetcher;
  const admin = (path, init = {}) => worker.fetch(new Request("https://relay.example" + path, { ...init, headers: { "x-admin-key": "admin-pass" } }), e, {});
  assert.equal((await worker.fetch(new Request("https://relay.example/admin/mod"), e, {})).status, 401);
  const servers = await (await admin("/admin/mod")).json();
  assert.deepEqual(servers.map((s) => [s.guild, s.name, s.cases]), [[GUILD, "Pup Town", 4]]);
  let page = await (await admin(`/admin/mod/${GUILD}/cases?limit=2`)).json();
  assert.deepEqual(page.cases.map((c) => c.n), [4, 3]);
  assert.equal(page.next, 3);
  page = await (await admin(`/admin/mod/${GUILD}/cases?limit=2&before=3`)).json();
  assert.deepEqual(page.cases.map((c) => c.n), [2, 1]);
  assert.equal(page.next, null);
  page = await (await admin(`/admin/mod/${GUILD}/cases?user=900`)).json();
  assert.deepEqual(page.cases.map((c) => c.n), [3, 2, 1]);
  const cleared = await (await admin(`/admin/mod/${GUILD}/cases/2/clear`, { method: "POST" })).json();
  assert.equal(cleared.case.cleared, true);
  assert.equal((await admin(`/admin/mod/${GUILD}/cases/2/clear`, { method: "POST" })).status, 400, "already cleared");
  assert.equal((await admin(`/admin/mod/${GUILD}/cases/4/clear`, { method: "POST" })).status, 400, "a note is not a warning");
  assert.equal((await admin(`/admin/mod/${GUILD}/cases/99/clear`, { method: "POST" })).status, 404);
});
