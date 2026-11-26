// PuppyAdmin presence server (Cloudflare Worker + one Durable Object per Roblox server).
//
// POST /beat  {"jobId": "<game.JobId>", "userId": 123, "active": true|false}
//   -> {"online": [userIds of everyone else running the script in that server]}
//
// Entries expire TTL_MS after their last check-in, so a crashed or closed
// client drops off by itself; active=false removes it at once (`kill`).
// Nothing is stored on disk: the list lives in memory and rebuilds from the
// next round of check-ins if the object is restarted.

const TTL_MS = 60_000;
const MAX_USERS_PER_SERVER = 200;
const MAX_BODY = 512;

export class Presence {
  constructor(state, env) {
    this.users = new Map(); // userId -> last check-in (ms)
  }

  async fetch(request) {
    const { userId, active } = await request.json();
    const now = Date.now();
    for (const [id, at] of this.users) {
      if (now - at > TTL_MS) this.users.delete(id);
    }
    if (active) {
      if (this.users.has(userId) || this.users.size < MAX_USERS_PER_SERVER) this.users.set(userId, now);
    } else {
      this.users.delete(userId);
    }
    const online = [...this.users.keys()].filter((id) => id !== userId);
    return json({ online });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method !== "POST" || url.pathname !== "/beat") return json({ error: "POST /beat" }, 404);
    const text = await request.text();
    if (text.length > MAX_BODY) return json({ error: "too large" }, 413);
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      return json({ error: "bad json" }, 400);
    }
    const jobId = typeof body.jobId === "string" ? body.jobId : "";
    const userId = Number(body.userId);
    if (!/^[\w-]{1,64}$/.test(jobId) || !Number.isSafeInteger(userId) || userId <= 0) {
      return json({ error: "bad fields" }, 400);
    }
    const stub = env.PRESENCE.get(env.PRESENCE.idFromName(jobId));
    return stub.fetch("https://presence/beat", {
      method: "POST",
      body: JSON.stringify({ userId, active: body.active !== false }),
    });
  },
};

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "content-type": "application/json" } });
}
