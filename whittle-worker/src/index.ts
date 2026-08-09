/**
 * Whittle gateway — the single audited relay between the app and PostHog.
 * Contract: docs/internal/2026-08-09-analytics-model.md.
 *
 * POST /e            schema-validated telemetry relay (202, fire-and-forget)
 * GET  /stats.json   aggregate counter (hourly cron -> KV; best effort)
 * GET  /             standalone product page (static assets)
 */

const GATEWAY_VERSION = "1";
const ENVELOPE = [
  "app_version", "os_version", "arch", "locale",
  "tz_offset_minutes", "schema_version",
];

/** Per-event property allowlist. Anything else is dropped at the door. */
const EVENTS: Record<string, string[]> = {
  first_boot: ENVELOPE,
  boot: ENVELOPE,
  scan_completed: ["photos_scanned_bucket", "groups_found_bucket", "library_size_bucket", "duration_bucket"],
  suggest_used: ["backend_kind", "model_name", "group_size", "outcome", "duration_bucket"],
  suggestion_decided: ["decision", "backend_kind", "model_name"],
  photos_deleted: ["count", "bytes_freed", "running_total_count", "running_total_bytes"],
  telemetry_error: ["component", "error_class"],
};

const STRING_CAP = 200;
const BATCH_CAP = 50;
const BODY_CAP = 128 * 1024;

const BACKENDS = new Set(["lm_studio", "ollama", "ai_studio"]);
const OUTCOMES = new Set(["ok", "parse_error", "http_error", "cancelled"]);
const DECISIONS = new Set(["accepted", "overridden"]);
const COMPONENTS = new Set(["judge", "scan", "delete", "telemetry"]);

function cleanEvent(raw: any): { event: string; distinct_id: string; timestamp: string; properties: Record<string, unknown> } | null {
  if (!raw || typeof raw !== "object") return null;
  const event = raw.event;
  if (typeof event !== "string" || !(event in EVENTS)) return null;
  const distinctId = raw.distinct_id;
  if (typeof distinctId !== "string" || distinctId.length === 0 || distinctId.length > 200) return null;
  const timestamp = raw.timestamp;
  if (typeof timestamp !== "string" || isNaN(Date.parse(timestamp))) return null;

  const props: Record<string, unknown> = { distinct_id: distinctId };
  const allowed = EVENTS[event];
  const src = raw.properties && typeof raw.properties === "object" ? raw.properties : {};
  for (const key of allowed) {
    const v = src[key];
    if (v === undefined || v === null) continue;
    const t = typeof v;
    if (t === "string" && v.length <= STRING_CAP) props[key] = v;
    else if (t === "number" && Number.isFinite(v)) props[key] = v;
    else if (t === "boolean") props[key] = v;
  }
  if (!saneEvent(event, props)) return null;
  props["$process_person_profile"] = false;
  return { event, distinct_id: distinctId, timestamp, properties: props };
}

function saneEvent(event: string, p: Record<string, unknown>): boolean {
  if (event === "photos_deleted") {
    if (typeof p.count !== "number" || p.count < 0 || p.count > 5000) return false;
    if (typeof p.bytes_freed !== "number" || p.bytes_freed < 0 || p.bytes_freed > 5e11) return false;
    return true;
  }
  if (event === "suggest_used") {
    if (p.backend_kind && !BACKENDS.has(p.backend_kind as string)) return false;
    if (p.outcome && !OUTCOMES.has(p.outcome as string)) return false;
    if (p.group_size !== undefined && (typeof p.group_size !== "number" || p.group_size < 1 || p.group_size > 30)) return false;
    return true;
  }
  if (event === "suggestion_decided") {
    if (!DECISIONS.has(p.decision as string)) return false;
    return true;
  }
  if (event === "telemetry_error") {
    if (!COMPONENTS.has(p.component as string)) return false;
    return true;
  }
  return true;
}

interface Env {
  STATS: KVNamespace;
  ASSETS: Fetcher;
  POSTHOG_HOST: string;
  POSTHOG_PROJECT_KEY?: string;
  POSTHOG_READ_KEY?: string;
  POSTHOG_PROJECT_ID?: string;
}

async function ingest(request: Request, env: Env): Promise<Response> {
  let body: any;
  try { body = await request.json(); }
  catch { return json({ recorded: 0, dropped: 0, error: "bad_json" }, 400); }
  if (!body || !Array.isArray(body.events) || body.events.length === 0) {
    return json({ recorded: 0, dropped: 0, error: "empty" }, 400);
  }

  const events = [];
  let dropped = 0;
  for (const raw of body.events.slice(0, BATCH_CAP)) {
    const clean = cleanEvent(raw);
    if (!clean) { dropped++; continue; }
    clean.properties.gateway = `whittle-gateway/${GATEWAY_VERSION}`;
    // Country from Cloudflare's edge geo (derived from the client IP at the
    // edge, never forwarded onward). PostHog's own GeoIP transformation is
    // disabled in the project settings — it ignores properties.$ip and
    // geo-locates the worker's egress instead (verified: a test event from
    // Chennai came back US). Raw IPs are discarded by the EU-org default.
    const country = request.cf?.country;
    if (country) clean.properties["$geoip_country_code"] = country;
    events.push(clean);
  }

  if (events.length > 0 && env.POSTHOG_PROJECT_KEY) {
    try {
      await fetch(`${env.POSTHOG_HOST}/e/`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ api_key: env.POSTHOG_PROJECT_KEY, batch: events }),
      });
    } catch { /* best effort; the app is fire-and-forget anyway */ }
  }
  return json({ recorded: events.length, dropped }, 202);
}

function json(obj: unknown, status: number): Response {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

/** Hourly: refresh the aggregate counter into KV. Best effort, never fails. */
async function refreshStats(env: Env): Promise<void> {
  const stats: Record<string, number | string> = { generated_at: new Date().toISOString() };

  try {
    const res = await fetch("https://api.github.com/repos/surendranb/whittle/releases/latest", {
      headers: { "user-agent": `whittle-gateway/${GATEWAY_VERSION}`, accept: "application/vnd.github+json" },
    });
    if (res.ok) {
      const rel = await res.json() as any;
      const dl = (rel.assets || []).reduce((s: number, a: any) => s + (a.download_count || 0), 0);
      stats.downloads = dl;
    }
  } catch { /* ignore */ }

  if (env.POSTHOG_READ_KEY && env.POSTHOG_PROJECT_ID) {
    try {
      const q = await fetch(`${env.POSTHOG_HOST}/api/projects/${env.POSTHOG_PROJECT_ID}/query/`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${env.POSTHOG_READ_KEY}`,
        },
        body: JSON.stringify({
          query: {
            kind: "HogQLQuery",
            query: `SELECT event, sum(count), sum(bytes_freed), count(DISTINCT distinct_id) ` +
                   `FROM events WHERE event IN ('photos_deleted','first_boot') GROUP BY event`,
          },
        }),
      });
      if (q.ok) {
        const data = await q.json() as any;
        for (const row of data?.results ?? []) {
          if (row[0] === "photos_deleted") {
            stats.photos_deleted = row[1] ?? 0;
            stats.bytes_freed = row[2] ?? 0;
          } else if (row[0] === "first_boot") {
            stats.installs = row[3] ?? 0;
          }
        }
      }
    } catch { /* ignore */ }
  }

  try { await env.STATS.put("stats.json", JSON.stringify(stats), { expirationTtl: 60 * 60 * 24 * 14 }); }
  catch { /* KV down; next cron retries */ }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "POST" && url.pathname === "/e") {
      if (Number(request.headers.get("content-length") || 0) > BODY_CAP) {
        return json({ recorded: 0, dropped: 0, error: "too_large" }, 413);
      }
      return ingest(request, env);
    }
    if (request.method === "GET" && url.pathname === "/stats.json") {
      const raw = await env.STATS.get("stats.json");
      const body = raw ?? JSON.stringify({ generated_at: null, downloads: 0 });
      return new Response(body, {
        headers: {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "public, max-age=300",
        },
      });
    }
    return env.ASSETS.fetch(request);
  },
  async scheduled(_event: unknown, env: Env): Promise<void> {
    await refreshStats(env);
  },
};
