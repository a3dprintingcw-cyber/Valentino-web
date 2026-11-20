// Fresha <-> website calendar bridge, so both booking systems can run side by side.
//
//   GET  /functions/v1/calendar?feed=CAL_KEY   iCal feed of website bookings and manual blocks.
//        Paste this URL into Fresha > Calendar sync > Import events, so Fresha blocks those times.
//   POST /functions/v1/calendar?sync=CAL_KEY   Reads Fresha's exported calendar (FRESHA_ICS_URL)
//        and saves its appointments as blocks, so the website hides those times. Run by cron.
//
// Secrets: CAL_KEY (long random text), FRESHA_ICS_URL (Fresha's export link).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
// Turn OFF "Verify JWT" for this function: Fresha can't send a login, CAL_KEY protects it.

const URL_ = Deno.env.get("SUPABASE_URL")!;
const SRK = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const KEY = Deno.env.get("CAL_KEY") || "";

const db = (path: string, init: RequestInit = {}) =>
  fetch(`${URL_}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: SRK, Authorization: `Bearer ${SRK}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });

// ---------- iCal helpers ----------
const icsDate = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const icsText = (s: string) => s.replace(/\\/g, "\\\\").replace(/[,;]/g, (c) => "\\" + c).replace(/\n/g, "\\n");

// Parse DTSTART/DTEND values. Curaçao has no daylight saving, so local and floating times are UTC-4.
function parseIcsTime(params: string, value: string): string | null {
  const v = value.trim();
  if (/VALUE=DATE(?!-)/.test(params) || /^\d{8}$/.test(v)) {
    const d = v.slice(0, 8);
    return `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}T00:00:00-04:00`;
  }
  const m = v.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);
  if (!m) return null;
  const [, y, mo, d, h, mi, s, z] = m;
  const base = `${y}-${mo}-${d}T${h}:${mi}:${s}`;
  if (z) return base + "Z";
  const tz = (params.match(/TZID=([^;:]+)/) || [])[1] || "America/Curacao";
  // any Caribbean/Atlantic UTC-4 zone without DST; other zones are converted with Intl
  if (/Curacao|Aruba|Puerto_Rico|Santo_Domingo|Port_of_Spain|Barbados|La_Paz|Caracas|Atlantic Standard|SA Western/i.test(tz)) return base + "-04:00";
  try {
    const guess = new Date(base + "Z");
    const parts = new Intl.DateTimeFormat("en-US", { timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" }).formatToParts(guess);
    const g = (t: string) => +parts.find((p) => p.type === t)!.value;
    const asLocal = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second"));
    return new Date(guess.getTime() - (asLocal - guess.getTime())).toISOString();
  } catch {
    return base + "-04:00";
  }
}

function parseIcs(text: string) {
  const lines = text.replace(/\r\n[ \t]/g, "").replace(/\n[ \t]/g, "").split(/\r?\n/);
  const events: { s: string; e: string; t: string }[] = [];
  let cur: Record<string, [string, string]> | null = null;
  for (const line of lines) {
    if (line === "BEGIN:VEVENT") cur = {};
    else if (line === "END:VEVENT" && cur) {
      const st = cur.DTSTART && parseIcsTime(cur.DTSTART[0], cur.DTSTART[1]);
      let en = cur.DTEND && parseIcsTime(cur.DTEND[0], cur.DTEND[1]);
      if (st && !en) en = new Date(Date.parse(st) + (cur.DTSTART[0].includes("VALUE=DATE") ? 864e5 : 30 * 6e4)).toISOString();
      const cancelled = (cur.STATUS?.[1] || "").toUpperCase() === "CANCELLED" || (cur.TRANSP?.[1] || "").toUpperCase() === "TRANSPARENT";
      if (st && en && !cancelled) events.push({ s: st, e: en, t: "Fresha booking" });
      cur = null;
    } else if (cur) {
      const i = line.indexOf(":");
      if (i < 0) continue;
      const [name, ...params] = line.slice(0, i).split(";");
      cur[name.toUpperCase()] = [params.join(";"), line.slice(i + 1)];
    }
  }
  return events;
}

// ---------- handlers ----------
async function feed() {
  const since = new Date(Date.now() - 864e5).toISOString();
  const [bk, bl] = await Promise.all([
    db(`bookings?select=id,starts_at,ends_at&status=eq.booked&ends_at=gt.${since}&order=starts_at`).then((r) => r.json()),
    db(`blocks?select=id,starts_at,ends_at&source=neq.fresha&ends_at=gt.${since}&order=starts_at`).then((r) => r.json()),
  ]);
  const stamp = icsDate(new Date().toISOString());
  const ev = (id: string, s: string, e: string, title: string) =>
    ["BEGIN:VEVENT", `UID:${id}@valentino-web`, `DTSTAMP:${stamp}`, `DTSTART:${icsDate(s)}`, `DTEND:${icsDate(e)}`, `SUMMARY:${icsText(title)}`, "TRANSP:OPAQUE", "END:VEVENT"].join("\r\n");
  const body = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Valentino The Barber//Website bookings//EN", "CALSCALE:GREGORIAN",
    "X-WR-CALNAME:Website bookings", "X-WR-TIMEZONE:America/Curacao", "REFRESH-INTERVAL;VALUE=DURATION:PT10M",
    ...(bk as any[]).map((b) => ev(b.id, b.starts_at, b.ends_at, "Website booking")),
    ...(bl as any[]).map((b) => ev(b.id, b.starts_at, b.ends_at, "Blocked on website")),
    "END:VCALENDAR",
  ].join("\r\n") + "\r\n";
  return new Response(body, { headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-cache" } });
}

async function sync() {
  const src = Deno.env.get("FRESHA_ICS_URL");
  if (!src) return Response.json({ ok: false, error: "FRESHA_ICS_URL not set" }, { status: 500 });
  const r = await fetch(src.replace(/^webcals?:\/\//, "https://"), { headers: { "User-Agent": "valentino-web-sync" } });
  if (!r.ok) return Response.json({ ok: false, error: `Fresha feed ${r.status}` }, { status: 502 });
  const text = await r.text();
  if (!text.includes("BEGIN:VCALENDAR")) return Response.json({ ok: false, error: "Not a calendar feed" }, { status: 502 });
  const events = parseIcs(text).filter((e) => Date.parse(e.e) > Date.now() - 864e5);
  const res = await db("rpc/replace_fresha_blocks", { method: "POST", body: JSON.stringify({ p_events: events }) });
  if (!res.ok) return Response.json({ ok: false, error: await res.text() }, { status: 500 });
  return Response.json({ ok: true, saved: await res.json() });
}

Deno.serve(async (req) => {
  const u = new URL(req.url);
  if (!KEY) return new Response("CAL_KEY not set", { status: 500 });
  if (u.searchParams.get("feed") === KEY) return feed();
  if (u.searchParams.get("sync") === KEY) return sync();
  return new Response("not found", { status: 404 });
});
