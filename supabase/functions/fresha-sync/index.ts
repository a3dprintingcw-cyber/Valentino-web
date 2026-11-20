// Reads Valentino's Fresha calendar export (an iCal link) and stores the appointment times,
// so the website shows them as taken. Called every 5 minutes by a cron job.
// The Fresha link and the shared secret live in the database (private.sync_config);
// Valentino sets the Fresha link on the admin page. Nothing to configure here.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.

const OFFSET = "-04:00"; // Curaçao, no daylight saving

function unfold(ics: string): string[] {
  return ics.replace(/\r\n/g, "\n").replace(/\n[ \t]/g, "").split("\n");
}

// DTSTART;TZID=...:20261120T140000 | DTSTART:20261120T180000Z | DTSTART;VALUE=DATE:20261120
function parseDate(line: string): { iso: string; allDay: boolean } | null {
  const i = line.indexOf(":");
  if (i < 0) return null;
  const params = line.slice(0, i), v = line.slice(i + 1).trim();
  let m = v.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$/);
  if (m) {
    const [, y, mo, d, h, mi, s, z] = m;
    // times with Z are UTC; times with a TZID or no zone are taken as shop time
    return { iso: `${y}-${mo}-${d}T${h}:${mi}:${s}${z ? "Z" : OFFSET}`, allDay: false };
  }
  m = v.match(/^(\d{4})(\d{2})(\d{2})$/);
  if (m || /VALUE=DATE/.test(params)) {
    const [, y, mo, d] = m ?? [];
    return { iso: `${y}-${mo}-${d}T00:00:00${OFFSET}`, allDay: true };
  }
  return null;
}

function parseEvents(ics: string) {
  const out: { uid: string; starts_at: string; ends_at: string; title: string }[] = [];
  let ev: Record<string, string> | null = null;
  for (const line of unfold(ics)) {
    if (line === "BEGIN:VEVENT") ev = {};
    else if (line === "END:VEVENT" && ev) {
      const s = ev.DTSTART ? parseDate(ev.DTSTART) : null;
      let e = ev.DTEND ? parseDate(ev.DTEND) : null;
      const cancelled = /CANCELLED/i.test(ev.STATUS ?? "") || /^TRANSPARENT/i.test(ev.TRANSP ?? "");
      if (s && !cancelled) {
        if (!e) e = { iso: new Date(Date.parse(s.iso) + (s.allDay ? 864e5 : 30 * 6e4)).toISOString(), allDay: s.allDay };
        const uid = ev.UID || `${s.iso}-${e.iso}`;
        // skip our own website bookings if Fresha sends them back
        if (!uid.endsWith("@valentino-web")) {
          out.push({ uid: "fresha:" + uid, starts_at: new Date(s.iso).toISOString(), ends_at: new Date(e.iso).toISOString(), title: (ev.SUMMARY ?? "").slice(0, 120) });
        }
      }
      ev = null;
    } else if (ev) {
      const key = line.split(/[;:]/)[0];
      if (["DTSTART", "DTEND", "UID", "SUMMARY", "STATUS", "TRANSP"].includes(key)) ev[key] = key.startsWith("DT") ? line : line.slice(line.indexOf(":") + 1);
    }
  }
  return out;
}

const db = (fn: string, body: unknown) =>
  fetch(`${Deno.env.get("SUPABASE_URL")}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      Authorization: `Bearer ${Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

Deno.serve(async (req) => {
  const cfg = await (await db("get_sync_config", {})).json();
  if (!cfg?.sync_secret || req.headers.get("x-sync-secret") !== cfg.sync_secret) return new Response("unauthorized", { status: 401 });
  if (!cfg.fresha_url) return new Response("no Fresha link set");

  const fail = async (msg: string) => { await db("set_sync_status", { p_count: null, p_error: msg }); return new Response(msg, { status: 502 }); };
  let ics = "";
  try {
    const res = await fetch(String(cfg.fresha_url).replace(/^webcal:/i, "https:"), { headers: { "User-Agent": "valentino-web-sync" } });
    if (!res.ok) return fail(`Fresha link answered ${res.status}`);
    ics = await res.text();
  } catch (e) { return fail(`Could not reach the Fresha link: ${(e as Error).message}`); }
  if (!ics.includes("BEGIN:VCALENDAR")) return fail("The Fresha link did not return a calendar");

  const now = Date.now();
  const rows = parseEvents(ics).filter((r) => Date.parse(r.ends_at) > now - 864e5 && Date.parse(r.starts_at) < now + 90 * 864e5);
  const r = await db("replace_external_busy", { p_source: "fresha", p_rows: rows });
  if (!r.ok) return fail(`Database error ${r.status}`);
  await db("set_sync_status", { p_count: rows.length, p_error: null });
  return new Response(JSON.stringify({ synced: rows.length }), { headers: { "Content-Type": "application/json" } });
});
