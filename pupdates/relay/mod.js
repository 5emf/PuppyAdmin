// Moderation + staff system for your bot: Discord slash commands answered by this Worker.
//
// Discord sends every slash command to https://<your relay>/interactions (Developer Portal > your app >
// General Information > Interactions Endpoint URL). The Worker checks Discord's signature
// (secret DISCORD_PUBLIC_KEY = the app's Public Key), answers within Discord's 3 seconds with
// "thinking...", then does the work with the bot's token (DISCORD_BOT_TOKEN) and edits the answer.
// Nothing runs on your PC. Install / update the commands from the Pupdates apps (Whitelist section)
// or with POST /admin/commands.
//
// Staff levels (per server, stored in KV):
//   4 owner      the server's owner, or a user id in the OWNER_IDS variable (comma separated)
//   3 admin      staff admins, and anyone with Discord's Administrator permission
//   2 moderator
//   1 helper
//   0 member
// Staff are users (/staff add) or roles (/staff role). Nobody can act on someone of the same or a
// higher level, on themselves or on the bot; levels can only be given below your own.
//
// Data per server: mod:<guild>:config  { log, announce, dm, nextCase, staff: { users, roles }, owner, name }
//                  mod:<guild>:case:<n> { n, type, user, userTag, mod, modTag, reason, at, minutes, cleared }
//                  mod:<guild>:user:<id> [ case numbers ]
//                  mod:guilds            { <guild id>: name }  (for the Pupdates apps' Moderation section)
// Automatic timeout: /modsettings auto_timeout_warns:3 auto_timeout_minutes:60 times a member out every
// time their active warnings reach a multiple of 3 (0 = off).

export const API = "https://discord.com/api/v10";
export const LEVELS = ["member", "helper", "moderator", "admin", "owner"];
const HELPER = 1, MODERATOR = 2, ADMIN = 3, OWNER = 4;
const ADMINISTRATOR = 1n << 3n;
const EPHEMERAL = 64;
const SEND_MESSAGES = 1n << 11n;
const MAX_TIMEOUT = 40320;           // minutes: Discord's limit is 28 days
const HELPER_TIMEOUT = 60;           // helpers may time out for an hour at most
const HELPER_PURGE = 25;
const COLORS = { warn: 0xf5b028, timeout: 0xf59b28, untimeout: 0x3f9b56, kick: 0xe0703a, ban: 0xd0453a, unban: 0x3f9b56,
                 note: 0x8a8d96, purge: 0x5865f2, lock: 0x8a8d96, unlock: 0x3f9b56, slowmode: 0x8a8d96, clearwarn: 0x3f9b56 };
const PAST = { warn: "warned", timeout: "timed out", untimeout: "no longer timed out", kick: "kicked", ban: "banned",
               unban: "unbanned", note: "given a staff note", clearwarn: "cleared of warnings" };

// ------------------------------------------------------------------ the commands Discord shows
const USER = (description = "Who", required = true) => ({ type: 6, name: "user", description, required });
const REASON = (required = false) => ({ type: 3, name: "reason", description: "Why (shown in the log, the audit log and the DM)", required, max_length: 400 });
const LEVEL_CHOICES = [{ name: "helper", value: 1 }, { name: "moderator", value: 2 }, { name: "admin", value: 3 }];
const cmd = (name, description, options = []) => ({ name, description, options, contexts: [0], type: 1 });

export const COMMANDS = [
  cmd("warn", "Warn a member (helper)", [USER("Who to warn"), REASON(true)]),
  cmd("warnings", "A member's warnings and other cases (helper)", [USER("Whose record")]),
  cmd("case", "Show one case (helper)", [{ type: 4, name: "number", description: "Case number", required: true, min_value: 1 }]),
  cmd("note", "Add a staff-only note about a member; they are not told (helper)", [USER("About whom"), { type: 3, name: "text", description: "The note", required: true, max_length: 400 }]),
  cmd("timeout", "Time a member out (helper: up to 60 minutes, moderator: up to 28 days)", [USER("Who"),
    { type: 4, name: "minutes", description: "How long, in minutes", required: true, min_value: 1, max_value: MAX_TIMEOUT }, REASON()]),
  cmd("untimeout", "End a member's timeout (helper)", [USER("Who"), REASON()]),
  cmd("purge", "Delete recent messages in this channel (helper: 25, moderator: 100)", [
    { type: 4, name: "count", description: "How many (1-100)", required: true, min_value: 1, max_value: 100 }, USER("Only this member's messages", false)]),
  cmd("kick", "Kick a member (moderator)", [USER("Who to kick"), REASON()]),
  cmd("clearwarn", "Clear a member's warnings, or one warning (moderator)", [USER("Whose warnings"),
    { type: 4, name: "case", description: "Only this case number", required: false, min_value: 1 }]),
  cmd("slowmode", "Set this channel's slowmode (moderator)", [{ type: 4, name: "seconds", description: "0 = off, up to 21600", required: true, min_value: 0, max_value: 21600 }]),
  cmd("lock", "Stop everyone from writing in this channel (moderator)", [REASON()]),
  cmd("unlock", "Let everyone write in this channel again (moderator)", [REASON()]),
  cmd("ban", "Ban a user, also one who is not in the server (admin)", [USER("Who to ban"), REASON(),
    { type: 4, name: "delete_messages", description: "Also delete their recent messages", required: false,
      choices: [{ name: "none", value: 0 }, { name: "last hour", value: 3600 }, { name: "last day", value: 86400 }, { name: "last 7 days", value: 604800 }] }]),
  cmd("unban", "Lift a ban (admin)", [{ type: 3, name: "user_id", description: "The banned user's id", required: true, max_length: 20 }, REASON()]),
  { name: "staff", description: "The staff team", contexts: [0], type: 1, options: [
    { type: 1, name: "list", description: "Who is on the staff team (helper)" },
    { type: 1, name: "add", description: "Add someone to the staff team, or change their level (admin)", options: [USER("Who"),
      { type: 4, name: "level", description: "Their level", required: true, choices: LEVEL_CHOICES }] },
    { type: 1, name: "remove", description: "Take someone off the staff team (admin)", options: [USER("Who")] },
    { type: 1, name: "role", description: "Give everyone with a role a staff level, or none (admin)", options: [
      { type: 8, name: "role", description: "The role", required: true },
      { type: 4, name: "level", description: "Their level", required: true, choices: [{ name: "none", value: 0 }, ...LEVEL_CHOICES] }] },
  ] },
  cmd("modsettings", "Moderation settings: log channel, public notices, DMs (admin)", [
    { type: 7, name: "log_channel", description: "Where every action is logged", required: false, channel_types: [0, 5] },
    { type: 5, name: "no_log", description: "Turn the log off", required: false },
    { type: 5, name: "announce", description: "Post a short public notice in the channel after an action", required: false },
    { type: 5, name: "dm_members", description: "Tell members by DM when they are warned, timed out, kicked or banned", required: false },
    { type: 4, name: "auto_timeout_warns", description: "Time out automatically at this many active warnings (0 = off)", required: false, min_value: 0, max_value: 20 },
    { type: 4, name: "auto_timeout_minutes", description: "How long the automatic timeout lasts, in minutes", required: false, min_value: 1, max_value: MAX_TIMEOUT }]),
  cmd("modhelp", "The moderation commands you can use"),
];

// ------------------------------------------------------------------ small helpers
export function hexBytes(hex) {
  const s = String(hex || "").trim();
  if (!/^([0-9a-f]{2})+$/i.test(s)) return null;
  return Uint8Array.from(s.match(/../g).map((b) => parseInt(b, 16)));
}

export async function verifySignature(publicKey, signature, timestamp, body, now = Date.now()) {
  const key = hexBytes(publicKey), sig = hexBytes(signature);
  if (!key || key.length !== 32 || !sig || sig.length !== 64 || !/^\d+$/.test(String(timestamp || ""))) return false;
  if (Math.abs(now / 1000 - Number(timestamp)) > 300) return false;          // an old, replayed request
  const data = new TextEncoder().encode(timestamp + body);
  for (const alg of [{ name: "Ed25519" }, { name: "NODE-ED25519", namedCurve: "NODE-ED25519" }]) {
    try {
      const k = await crypto.subtle.importKey("raw", key, alg, false, ["verify"]);
      return await crypto.subtle.verify(alg, k, sig, data);
    } catch { /* this runtime calls it the other name */ }
  }
  return false;
}

export function appIdFromToken(token) {
  try {
    const part = String(token || "").split(".")[0].replace(/-/g, "+").replace(/_/g, "/");
    const id = atob(part + "===".slice((part.length + 3) % 4));
    return /^\d{15,22}$/.test(id) ? id : null;
  } catch { return null; }
}

export function snowflakeTime(id) {
  try { return Number((BigInt(id) >> 22n) + 1420070400000n); } catch { return 0; }
}

function tag(user) {
  if (!user) return "unknown";
  return user.discriminator && user.discriminator !== "0" ? `${user.username}#${user.discriminator}` : (user.global_name ? `${user.global_name} (@${user.username})` : `@${user.username}`);
}

function options(data) {
  let opts = data.options || [];
  let sub = null;
  if (opts.length && opts[0].type === 1) { sub = opts[0].name; opts = opts[0].options || []; }
  const o = {};
  for (const x of opts) o[x.name] = x.value;
  return { sub, o };
}

export function minutesText(m) {
  if (m % 1440 === 0) return `${m / 1440} day${m === 1440 ? "" : "s"}`;
  if (m % 60 === 0) return `${m / 60} hour${m === 60 ? "" : "s"}`;
  return `${m} minute${m === 1 ? "" : "s"}`;
}

const ERRORS = {
  50013: "The bot is missing a permission for that, or its role is not above that member's highest role (Server Settings > Roles: drag the bot's role up)",
  50001: "The bot cannot see this channel",
  10007: "That member is not in the server",
  10013: "That user does not exist",
  10026: "That user is not banned",
  50034: "Only messages younger than 14 days can be deleted in bulk",
  50035: "Discord did not accept the values",
};

// ------------------------------------------------------------------ the Discord REST calls (with the bot's token)
export function discord(env, fetcher = (...a) => fetch(...a)) {
  return async function call(method, path, body, reason) {
    const headers = { authorization: "Bot " + env.DISCORD_BOT_TOKEN, "user-agent": "DiscordBot (https://github.com/5emf/PuppyAdmin, 2) Pupdates relay" };
    if (body !== undefined) headers["content-type"] = "application/json";
    if (reason) headers["x-audit-log-reason"] = encodeURIComponent(String(reason).slice(0, 400));
    for (let attempt = 0; attempt < 3; attempt++) {
      const res = await fetcher(API + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
      const text = await res.text();
      let data = null;
      try { data = text ? JSON.parse(text) : null; } catch { data = null; }
      if (res.status === 429 && attempt < 2) {
        await new Promise((r) => setTimeout(r, Math.min(5, Number((data && data.retry_after) || 1)) * 1000));
        continue;
      }
      if (!res.ok) {
        const e = new Error((data && ERRORS[data.code]) || (data && data.message) || `Discord answered HTTP ${res.status}`);
        e.status = res.status; e.code = data && data.code;
        throw e;
      }
      return data;
    }
    throw new Error("Discord is rate-limiting the bot: try again in a moment");
  };
}

// ------------------------------------------------------------------ storage
async function getConfig(env, guild) {
  const c = JSON.parse((await env.PUPDATES.get(`mod:${guild}:config`)) || "{}");
  return { log: c.log || "", announce: c.announce !== false, dm: c.dm !== false, nextCase: c.nextCase || 1,
           staff: { users: (c.staff && c.staff.users) || {}, roles: (c.staff && c.staff.roles) || {} },
           owner: c.owner || "", name: c.name || "", autoWarns: c.autoWarns || 0, autoMinutes: c.autoMinutes || 60 };
}
const putConfig = (env, guild, c) => env.PUPDATES.put(`mod:${guild}:config`, JSON.stringify(c));

async function guildInfo(env, api, guild, cfg) {
  if (!cfg.owner) {
    try {
      const g = await api("GET", `/guilds/${guild}`);
      cfg.owner = g.owner_id || ""; cfg.name = g.name || "";
      await putConfig(env, guild, cfg);
    } catch { /* the owner check falls back to Administrator */ }
  }
  const index = JSON.parse((await env.PUPDATES.get("mod:guilds")) || "{}");
  if (index[guild] !== (cfg.name || guild)) {
    index[guild] = cfg.name || guild;
    await env.PUPDATES.put("mod:guilds", JSON.stringify(index));
  }
  return cfg;
}

async function addCase(env, guild, cfg, c) {
  c.n = cfg.nextCase;
  cfg.nextCase += 1;
  await putConfig(env, guild, cfg);
  await env.PUPDATES.put(`mod:${guild}:case:${c.n}`, JSON.stringify(c));
  const key = `mod:${guild}:user:${c.user}`;
  const list = JSON.parse((await env.PUPDATES.get(key)) || "[]");
  list.push(c.n);
  await env.PUPDATES.put(key, JSON.stringify(list.slice(-200)));
  return c;
}

async function userCases(env, guild, user) {
  const list = JSON.parse((await env.PUPDATES.get(`mod:${guild}:user:${user}`)) || "[]");
  const out = [];
  for (const n of list) {
    const c = await env.PUPDATES.get(`mod:${guild}:case:${n}`);
    if (c) out.push(JSON.parse(c));
  }
  return out;
}

// ------------------------------------------------------------------ levels
export function levelOf(userId, member, cfg, env) {
  const owners = String(env.OWNER_IDS || "").split(/[\s,]+/).filter(Boolean);
  if (owners.includes(userId) || (cfg.owner && cfg.owner === userId)) return OWNER;
  let level = 0;
  try { if (member && member.permissions && (BigInt(member.permissions) & ADMINISTRATOR)) level = ADMIN; } catch { /* no permissions given */ }
  level = Math.max(level, Number(cfg.staff.users[userId] || 0));
  for (const r of (member && member.roles) || []) level = Math.max(level, Number(cfg.staff.roles[r] || 0));
  return Math.min(level, ADMIN);
}

const NEEDS = { warn: HELPER, warnings: HELPER, case: HELPER, note: HELPER, timeout: HELPER, untimeout: HELPER, purge: HELPER,
                kick: MODERATOR, clearwarn: MODERATOR, slowmode: MODERATOR, lock: MODERATOR, unlock: MODERATOR,
                ban: ADMIN, unban: ADMIN, modsettings: ADMIN, modhelp: 0,
                "staff list": HELPER, "staff add": ADMIN, "staff remove": ADMIN, "staff role": ADMIN };

// ------------------------------------------------------------------ the interaction itself
const reply = (content, flags = EPHEMERAL) => ({ type: 4, data: { content, flags, allowed_mentions: { parse: [] } } });

function embed(type, target, actor, reason, extra = {}) {
  const e = { color: COLORS[type] || 0x8a8d96, timestamp: new Date().toISOString(), fields: [] };
  e.author = { name: `${type.toUpperCase()}${extra.n ? "  ·  case #" + extra.n : ""}` };
  if (target) e.fields.push({ name: "Member", value: `<@${target.id}> (${tag(target)})`, inline: true });
  e.fields.push({ name: "By", value: `<@${actor.id}>`, inline: true });
  if (extra.minutes) e.fields.push({ name: "For", value: minutesText(extra.minutes), inline: true });
  if (extra.channel) e.fields.push({ name: "Channel", value: `<#${extra.channel}>`, inline: true });
  if (extra.count !== undefined) e.fields.push({ name: "Deleted", value: String(extra.count), inline: true });
  if (reason) e.fields.push({ name: extra.noteLabel || "Reason", value: String(reason).slice(0, 1000) });
  return e;
}

function caseLine(c) {
  const when = `<t:${Math.floor(c.at / 1000)}:d>`;
  const what = (c.type === "timeout" ? `timeout ${minutesText(c.minutes)}` : c.type) + (c.auto ? " (automatic)" : "");
  return `**#${c.n}** ${what}${c.cleared ? " (cleared)" : ""} ${when} by <@${c.mod}>${c.reason ? ": " + c.reason.slice(0, 120) : ""}`;
}

/**
 * Handles one interaction. Returns the immediate answer; slow work is handed to waitUntil and
 * finishes by editing that answer. fetcher is fetch (tests pass a fake).
 */
export async function handleInteraction(i, env, waitUntil, fetcher = (...a) => fetch(...a)) {
  if (i.type === 1) return { type: 1 };                        // Discord's check that the URL works
  if (i.type !== 2) return reply("This kind of interaction is not handled.");
  if (!i.guild_id) return reply("Use these commands in a server.");
  const api = discord(env, fetcher);
  const { sub, o } = options(i.data);
  const name = sub ? `${i.data.name} ${sub}` : i.data.name;
  if (!(name in NEEDS)) return reply("Unknown command: install the commands again from Pupdates.");
  const guild = i.guild_id;
  const actor = i.member.user;
  const cfg = await guildInfo(env, api, guild, await getConfig(env, guild));
  const level = levelOf(actor.id, i.member, cfg, env);
  if (level < NEEDS[name]) {
    return reply(`You need to be **${LEVELS[NEEDS[name]]}** or higher for /${name} (you are ${LEVELS[level]}).`);
  }
  const resolved = i.data.resolved || {};
  const target = o.user ? (resolved.users || {})[o.user] || { id: o.user, username: o.user } : null;
  const targetMember = o.user ? (resolved.members || {})[o.user] || null : null;

  // checks that need no Discord call, answered at once (only the person who used the command sees them)
  if (target && !["warnings", "staff remove", "purge"].includes(name)) {
    if (target.id === actor.id && name !== "staff add") return reply("Not on yourself.");
    if (target.id === i.application_id || target.bot) return reply("Not on bots.");
    const theirs = levelOf(target.id, targetMember, cfg, env);
    if (theirs >= level) return reply(`You cannot do that to a ${LEVELS[theirs]} (you are ${LEVELS[level]}).`);
    if (["timeout", "kick", "untimeout"].includes(name) && !targetMember) return reply("That member is not in the server.");
  }
  if (name === "timeout" && level < MODERATOR && o.minutes > HELPER_TIMEOUT) return reply(`Helpers can time out for ${HELPER_TIMEOUT} minutes at most.`);
  if (name === "purge" && level < MODERATOR && o.count > HELPER_PURGE) return reply(`Helpers can delete ${HELPER_PURGE} messages at most.`);
  if (name === "staff add" || name === "staff role") {
    if (o.level >= level) return reply(`You can only give levels below your own (you are ${LEVELS[level]}).`);
  }
  if (name === "staff add" && target && target.id === actor.id) return reply("You cannot change your own level.");
  if (name === "staff remove") {
    const theirs = Number(cfg.staff.users[o.user] || 0);
    if (!theirs) return reply(`<@${o.user}> is not on the staff list (a staff role may still give them a level: see /staff list).`);
    if (theirs >= level) return reply(`You cannot remove a ${LEVELS[theirs]} (you are ${LEVELS[level]}).`);
  }
  if (name === "staff role" && cfg.staff.roles[o.role] >= level) return reply("That role's level is not below yours.");

  const work = run(name, o, { i, env, api, cfg, guild, actor, level, target, targetMember, resolved })
    .catch((e) => "Could not do it: " + (e && e.message ? e.message : String(e)))
    .then((content) => api("PATCH", `/webhooks/${i.application_id}/${i.token}/messages/@original`,
      { content: String(content).slice(0, 1900), allowed_mentions: { parse: [] } }))
    .catch(() => {});
  waitUntil(work);
  // "thinking...", edited when the work is done; the answer is private, actions also post a public notice
  return { type: 5, data: { flags: EPHEMERAL } };
}

async function notify(ctx, type, target, reason, extra) {
  const { api, cfg, actor, i } = ctx;
  const e = embed(type, target, actor, reason, extra);
  if (cfg.log) {
    try { await api("POST", `/channels/${cfg.log}/messages`, { embeds: [e], allowed_mentions: { parse: [] } }); } catch { /* the log is best effort */ }
  }
  if (cfg.announce && type !== "note" && i.channel_id !== cfg.log) {
    const who = target ? `<@${target.id}>` : `<#${i.channel_id}>`;
    const text = type === "purge" ? `🧹 ${extra.count} message${extra.count === 1 ? "" : "s"} deleted.`
      : type === "lock" ? "🔒 This channel is locked." : type === "unlock" ? "🔓 This channel is open again."
      : type === "slowmode" ? (extra.seconds ? `🐢 Slowmode: one message every ${extra.seconds} s.` : "Slowmode is off.")
      : `${who} was ${PAST[type]}${extra.minutes ? " for " + minutesText(extra.minutes) : ""}${reason ? ": " + reason : "."}`;
    try { await api("POST", `/channels/${i.channel_id}/messages`, { content: text.slice(0, 1900), allowed_mentions: { parse: [] } }); } catch { /* best effort */ }
  }
}

async function dm(ctx, target, text) {
  if (!ctx.cfg.dm || !target) return false;
  try {
    const ch = await ctx.api("POST", "/users/@me/channels", { recipient_id: target.id });
    await ctx.api("POST", `/channels/${ch.id}/messages`, { content: text.slice(0, 1900), allowed_mentions: { parse: [] } });
    return true;
  } catch { return false; }                                      // DMs closed: the action still happens
}

function record(ctx, type, reason, extra = {}) {
  const { env, guild, cfg, target, actor } = ctx;
  return addCase(env, guild, cfg, { type, user: target ? target.id : "", userTag: tag(target), mod: actor.id, modTag: tag(actor),
                                    reason: reason || "", at: Date.now(), ...extra });
}

/** after a warning: the automatic timeout when the active warnings reach a multiple of cfg.autoWarns */
export function autoDue(cfg, warns) {
  return cfg.autoWarns > 0 && warns > 0 && warns % cfg.autoWarns === 0;
}

async function autoTimeout(ctx, warns) {
  const { cfg, api, guild, target, i } = ctx;
  if (!autoDue(cfg, warns)) return "";
  if (!ctx.targetMember) return " (Not in the server, so no automatic timeout.)";
  const minutes = Math.min(MAX_TIMEOUT, cfg.autoMinutes || 60);
  const why = `automatic: ${warns} warnings`;
  try {
    await api("PATCH", `/guilds/${guild}/members/${target.id}`,
      { communication_disabled_until: new Date(Date.now() + minutes * 60000).toISOString() }, why);
  } catch (e) {
    return ` The automatic timeout failed: ${e.message}`;
  }
  const bot = { ...ctx, actor: { id: i.application_id, username: "automatic" } };
  const c = await record(bot, "timeout", why, { minutes, auto: true });
  await dm(bot, target, `⏳ You were timed out in **${cfg.name || "the server"}** for ${minutesText(minutes)}: ${warns} warnings.`);
  await notify(bot, "timeout", target, why, { n: c.n, minutes });
  return ` ${warns} warnings: timed out automatically for ${minutesText(minutes)} (case #${c.n}).`;
}

async function run(name, o, ctx) {
  const { env, api, cfg, guild, actor, target, i } = ctx;   // eslint-disable-line no-unused-vars
  const server = cfg.name || "the server";
  const reason = (o.reason || "").trim();
  const audit = `${tag(actor)}: ${reason || "no reason given"}`;
  switch (name) {
    case "modhelp": {
      const mine = Object.entries(NEEDS).filter(([, need]) => need <= ctx.level).map(([n]) => "/" + n);
      return `You are **${LEVELS[ctx.level]}**. You can use: ${mine.join(", ")}.`;
    }
    case "warn": {
      const c = await record(ctx, "warn", reason);
      const told = await dm(ctx, target, `⚠️ You were warned in **${server}**: ${reason}`);
      const warns = (await userCases(env, guild, target.id)).filter((x) => x.type === "warn" && !x.cleared).length;
      await notify(ctx, "warn", target, reason, { n: c.n });
      const auto = await autoTimeout(ctx, warns);
      return `Warned <@${target.id}> (case #${c.n}, ${warns} warning${warns === 1 ? "" : "s"} now)${told ? "" : "; they could not be told by DM"}.${auto}`;
    }
    case "note": {
      const c = await record(ctx, "note", o.text);
      await notify(ctx, "note", target, o.text, { n: c.n, noteLabel: "Note" });
      return `Note added about <@${target.id}> (case #${c.n}). They were not told.`;
    }
    case "warnings": {
      const cases = await userCases(env, guild, target.id);
      if (!cases.length) return `<@${target.id}> has a clean record.`;
      const warns = cases.filter((x) => x.type === "warn" && !x.cleared).length;
      const lines = cases.slice(-15).reverse().map(caseLine);
      return `**${tag(target)}**: ${warns} active warning${warns === 1 ? "" : "s"}, ${cases.length} case${cases.length === 1 ? "" : "s"}${cases.length > 15 ? " (latest 15)" : ""}\n${lines.join("\n")}`;
    }
    case "case": {
      const c = JSON.parse((await env.PUPDATES.get(`mod:${guild}:case:${o.number}`)) || "null");
      return c ? `${caseLine(c)}\nMember: <@${c.user}> (${c.userTag})` : `There is no case #${o.number}.`;
    }
    case "clearwarn": {
      const cases = (await userCases(env, guild, target.id)).filter((x) => x.type === "warn" && !x.cleared && (!o.case || x.n === o.case));
      if (!cases.length) return o.case ? `Case #${o.case} is not an active warning of <@${target.id}>.` : `<@${target.id}> has no active warnings.`;
      for (const c of cases) { c.cleared = true; await env.PUPDATES.put(`mod:${guild}:case:${c.n}`, JSON.stringify(c)); }
      const c = await record(ctx, "clearwarn", `cleared ${cases.map((x) => "#" + x.n).join(", ")}`);
      await notify(ctx, "clearwarn", target, c.reason, { n: c.n });
      return `Cleared ${cases.length} warning${cases.length === 1 ? "" : "s"} of <@${target.id}> (case #${c.n}).`;
    }
    case "timeout": {
      const until = new Date(Date.now() + o.minutes * 60000).toISOString();
      await api("PATCH", `/guilds/${guild}/members/${target.id}`, { communication_disabled_until: until }, audit);
      const c = await record(ctx, "timeout", reason, { minutes: o.minutes });
      await dm(ctx, target, `⏳ You were timed out in **${server}** for ${minutesText(o.minutes)}${reason ? ": " + reason : "."}`);
      await notify(ctx, "timeout", target, reason, { n: c.n, minutes: o.minutes });
      return `Timed out <@${target.id}> for ${minutesText(o.minutes)} (case #${c.n}).`;
    }
    case "untimeout": {
      await api("PATCH", `/guilds/${guild}/members/${target.id}`, { communication_disabled_until: null }, audit);
      const c = await record(ctx, "untimeout", reason);
      await notify(ctx, "untimeout", target, reason, { n: c.n });
      return `<@${target.id}> can talk again (case #${c.n}).`;
    }
    case "kick": {
      const told = await dm(ctx, target, `👢 You were kicked from **${server}**${reason ? ": " + reason : "."}`);
      await api("DELETE", `/guilds/${guild}/members/${target.id}`, undefined, audit);
      const c = await record(ctx, "kick", reason);
      await notify(ctx, "kick", target, reason, { n: c.n });
      return `Kicked <@${target.id}> (case #${c.n})${told ? "" : "; they could not be told by DM"}.`;
    }
    case "ban": {
      const told = ctx.targetMember ? await dm(ctx, target, `🔨 You were banned from **${server}**${reason ? ": " + reason : "."}`) : false;
      await api("PUT", `/guilds/${guild}/bans/${target.id}`, { delete_message_seconds: o.delete_messages || 0 }, audit);
      const c = await record(ctx, "ban", reason);
      await notify(ctx, "ban", target, reason, { n: c.n });
      return `Banned <@${target.id}> (case #${c.n})${told || !ctx.targetMember ? "" : "; they could not be told by DM"}.`;
    }
    case "unban": {
      const id = String(o.user_id || "").trim();
      if (!/^\d{15,22}$/.test(id)) return "That is not a user id (Developer Mode on, right-click the user > Copy User ID).";
      await api("DELETE", `/guilds/${guild}/bans/${id}`, undefined, audit);
      ctx.target = { id, username: id };
      const c = await record(ctx, "unban", reason);
      await notify(ctx, "unban", ctx.target, reason, { n: c.n });
      return `Unbanned <@${id}> (case #${c.n}).`;
    }
    case "purge": {
      const msgs = await api("GET", `/channels/${i.channel_id}/messages?limit=100`);
      const young = Date.now() - 14 * 86400000 + 60000;
      const pick = msgs.filter((m) => (!o.user || m.author.id === o.user) && snowflakeTime(m.id) > young).slice(0, o.count).map((m) => m.id);
      if (!pick.length) return "No messages to delete (only messages younger than 14 days can be deleted).";
      if (pick.length === 1) await api("DELETE", `/channels/${i.channel_id}/messages/${pick[0]}`, undefined, audit);
      else await api("POST", `/channels/${i.channel_id}/messages/bulk-delete`, { messages: pick }, audit);
      ctx.target = o.user ? ctx.target : null;
      await notify(ctx, "purge", ctx.target, reason, { channel: i.channel_id, count: pick.length });
      return `Deleted ${pick.length} message${pick.length === 1 ? "" : "s"}.`;
    }
    case "slowmode": {
      await api("PATCH", `/channels/${i.channel_id}`, { rate_limit_per_user: o.seconds }, audit);
      await notify(ctx, "slowmode", null, "", { channel: i.channel_id, seconds: o.seconds });
      return o.seconds ? `Slowmode is ${o.seconds} s here.` : "Slowmode is off here.";
    }
    case "lock":
    case "unlock": {
      const ch = await api("GET", `/channels/${i.channel_id}`);
      const ow = (ch.permission_overwrites || []).find((x) => x.id === guild) || { allow: "0", deny: "0" };
      let allow = BigInt(ow.allow || "0"), deny = BigInt(ow.deny || "0");
      if (name === "lock") { deny |= SEND_MESSAGES; allow &= ~SEND_MESSAGES; } else { deny &= ~SEND_MESSAGES; }
      await api("PUT", `/channels/${i.channel_id}/permissions/${guild}`, { type: 0, allow: allow.toString(), deny: deny.toString() }, audit);
      await notify(ctx, name, null, reason, { channel: i.channel_id });
      return name === "lock" ? "Locked: only people with their own permission to write here can write now." : "Unlocked.";
    }
    case "staff list": {
      const by = { 3: [], 2: [], 1: [] };
      for (const [id, l] of Object.entries(cfg.staff.users)) by[l] && by[l].push(`<@${id}>`);
      for (const [id, l] of Object.entries(cfg.staff.roles)) by[l] && by[l].push(`<@&${id}> (role)`);
      const owners = [cfg.owner, ...String(env.OWNER_IDS || "").split(/[\s,]+/)].filter(Boolean);
      const lines = [`**owner**: ${[...new Set(owners)].map((x) => `<@${x}>`).join(", ") || "the server owner"}`];
      for (const l of [3, 2, 1]) lines.push(`**${LEVELS[l]}**: ${by[l].join(", ") || "nobody"}`);
      lines.push("People with Discord's Administrator permission count as admin.");
      return lines.join("\n");
    }
    case "staff add": {
      cfg.staff.users[target.id] = o.level;
      await putConfig(env, guild, cfg);
      return `<@${target.id}> is now **${LEVELS[o.level]}**.`;
    }
    case "staff remove": {
      delete cfg.staff.users[o.user];
      await putConfig(env, guild, cfg);
      return `<@${o.user}> is no longer on the staff list.`;
    }
    case "staff role": {
      if (o.level) cfg.staff.roles[o.role] = o.level; else delete cfg.staff.roles[o.role];
      await putConfig(env, guild, cfg);
      return o.level ? `Everyone with <@&${o.role}> is now **${LEVELS[o.level]}**.` : `<@&${o.role}> no longer gives a staff level.`;
    }
    case "modsettings": {
      if (o.log_channel) cfg.log = o.log_channel;
      if (o.no_log) cfg.log = "";
      if (o.announce !== undefined) cfg.announce = o.announce;
      if (o.dm_members !== undefined) cfg.dm = o.dm_members;
      if (o.auto_timeout_warns !== undefined) cfg.autoWarns = o.auto_timeout_warns;
      if (o.auto_timeout_minutes !== undefined) cfg.autoMinutes = o.auto_timeout_minutes;
      await putConfig(env, guild, cfg);
      return `Log: ${cfg.log ? `<#${cfg.log}>` : "off"} · public notices: ${cfg.announce ? "on" : "off"} · DMs to members: ${cfg.dm ? "on" : "off"}` +
        ` · automatic timeout: ${cfg.autoWarns ? `${minutesText(cfg.autoMinutes)} at every ${cfg.autoWarns} warnings` : "off"}`;
    }
  }
  return "Unknown command.";
}

// ------------------------------------------------------------------ the Pupdates apps' Moderation section (admin key, via worker.js)
const jsonResponse = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

/**
 * GET  /admin/mod                                   -> [{ guild, name, cases, log, announce, dm, autoWarns, autoMinutes, staff }]
 * GET  /admin/mod/<guild>/cases?user=<id>&before=<n>&limit=<1..50>  -> { cases (newest first), next }
 * POST /admin/mod/<guild>/cases/<n>/clear            -> clears one active warning
 */
export async function adminMod(request, env, path) {
  if (path === "/admin/mod" && request.method === "GET") {
    const index = JSON.parse((await env.PUPDATES.get("mod:guilds")) || "{}");
    const out = [];
    for (const [guild, name] of Object.entries(index)) {
      const c = await getConfig(env, guild);
      out.push({ guild, name: c.name || name, cases: c.nextCase - 1, log: c.log, announce: c.announce, dm: c.dm,
                 autoWarns: c.autoWarns, autoMinutes: c.autoMinutes,
                 staff: { users: Object.keys(c.staff.users).length, roles: Object.keys(c.staff.roles).length } });
    }
    return jsonResponse(out.sort((a, b) => a.name.localeCompare(b.name)));
  }
  let m = path.match(/^\/admin\/mod\/(\d{15,22})\/cases$/);
  if (m && request.method === "GET") {
    const guild = m[1];
    const q = new URL(request.url).searchParams;
    const limit = Math.max(1, Math.min(50, Number(q.get("limit")) || 25));
    const user = (q.get("user") || "").trim();
    const before = Number(q.get("before")) || Infinity;
    let numbers;
    if (user) {
      if (!/^\d{1,22}$/.test(user)) return jsonResponse({ error: "A user id is digits only" }, 400);
      numbers = JSON.parse((await env.PUPDATES.get(`mod:${guild}:user:${user}`)) || "[]").filter((n) => n < before).reverse();
    } else {
      const top = Math.min((await getConfig(env, guild)).nextCase - 1, before - 1);
      numbers = [];
      for (let n = top; n >= 1 && numbers.length < limit + 1; n--) numbers.push(n);
    }
    const cases = [];
    for (const n of numbers.slice(0, limit)) {
      const c = await env.PUPDATES.get(`mod:${guild}:case:${n}`);
      if (c) cases.push(JSON.parse(c));
    }
    return jsonResponse({ cases, next: numbers.length > limit ? cases[cases.length - 1].n : null });
  }
  m = path.match(/^\/admin\/mod\/(\d{15,22})\/cases\/(\d+)\/clear$/);
  if (m && request.method === "POST") {
    const key = `mod:${m[1]}:case:${m[2]}`;
    const c = JSON.parse((await env.PUPDATES.get(key)) || "null");
    if (!c) return jsonResponse({ error: `There is no case #${m[2]}` }, 404);
    if (c.type !== "warn" || c.cleared) return jsonResponse({ error: `Case #${m[2]} is not an active warning` }, 400);
    c.cleared = true;
    c.clearedBy = "Pupdates app";
    await env.PUPDATES.put(key, JSON.stringify(c));
    return jsonResponse({ ok: true, case: c });
  }
  return jsonResponse({ error: "Unknown moderation request" }, 404);
}

// ------------------------------------------------------------------ HTTP entry points (called from worker.js)
export async function interactionsRoute(request, env, ctx, fetcher) {
  if (request.method !== "POST") return new Response("Discord sends slash commands here.", { status: 405 });
  if (!env.DISCORD_PUBLIC_KEY || !env.DISCORD_BOT_TOKEN || !env.PUPDATES) {
    return new Response("Set DISCORD_PUBLIC_KEY, DISCORD_BOT_TOKEN and the PUPDATES KV binding", { status: 500 });
  }
  const body = await request.text();
  const ok = await verifySignature(env.DISCORD_PUBLIC_KEY, request.headers.get("x-signature-ed25519"), request.headers.get("x-signature-timestamp"), body);
  if (!ok) return new Response("Bad signature", { status: 401 });
  let i;
  try { i = JSON.parse(body); } catch { return new Response("Not JSON", { status: 400 }); }
  const waitUntil = (p) => (ctx && ctx.waitUntil ? ctx.waitUntil(p) : p);
  const answer = await handleInteraction(i, env, waitUntil, fetcher);
  return new Response(JSON.stringify(answer), { headers: { "content-type": "application/json" } });
}

/** PUT the command list to Discord (POST /admin/commands). */
export async function installCommands(env, origin, fetcher) {
  const app = env.DISCORD_APPLICATION_ID || appIdFromToken(env.DISCORD_BOT_TOKEN);
  if (!env.DISCORD_BOT_TOKEN || !app) throw new Error("Set DISCORD_BOT_TOKEN on the relay first");
  const done = await discord(env, fetcher)("PUT", `/applications/${app}/commands`, COMMANDS);
  return { ok: true, count: Array.isArray(done) ? done.length : COMMANDS.length, application: app,
           interactionsUrl: origin + "/interactions", publicKeySet: Boolean(env.DISCORD_PUBLIC_KEY) };
}
