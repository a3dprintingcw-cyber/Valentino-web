// Calendar link with all website bookings and blocked time, for Fresha to import as blocked time.
// URL: https://<project>.supabase.co/functions/v1/calendar-feed?token=FEED_TOKEN
// The token lives in the database (private.sync_config); the admin page shows the full link.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

const stamp = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
const text = (s: string) => s.replace(/[\\;,]/g, (c) => "\\" + c).replace(/\n/g, "\\n");

Deno.serve(async (req) => {
  const base = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const h = { apikey: key, Authorization: `Bearer ${key}` };
  const token = new URL(req.url).searchParams.get("token");
  const cfg = await fetch(`${base}/rest/v1/rpc/get_sync_config`, { method: "POST", headers: { ...h, "Content-Type": "application/json" }, body: "{}" }).then((r) => r.json());
  if (!token || !cfg?.feed_token || token !== cfg.feed_token) return new Response("not found", { status: 404 });
  const since = new Date(Date.now() - 864e5).toISOString();
  const [bookings, blocks] = await Promise.all([
    fetch(`${base}/rest/v1/bookings?select=id,starts_at,ends_at,name,items,created_at&status=eq.booked&ends_at=gt.${since}`, { headers: h }).then((r) => r.json()),
    fetch(`${base}/rest/v1/blocks?select=id,starts_at,ends_at,reason,created_at&ends_at=gt.${since}`, { headers: h }).then((r) => r.json()),
  ]);

  const now = stamp(new Date().toISOString());
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Valentino The Barber//Website bookings//EN",
    "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Valentino website bookings", "X-PUBLISHED-TTL:PT5M",
  ];
  for (const b of Array.isArray(bookings) ? bookings : []) {
    const services = (b.items || []).map((i: { name: string }) => i.name).join(", ");
    lines.push("BEGIN:VEVENT", `UID:${b.id}@valentino-web`, `DTSTAMP:${now}`, `DTSTART:${stamp(b.starts_at)}`, `DTEND:${stamp(b.ends_at)}`,
      `SUMMARY:${text(`Website: ${b.name}${services ? " (" + services + ")" : ""}`)}`, "TRANSP:OPAQUE", "END:VEVENT");
  }
  for (const k of Array.isArray(blocks) ? blocks : []) {
    lines.push("BEGIN:VEVENT", `UID:block-${k.id}@valentino-web`, `DTSTAMP:${now}`, `DTSTART:${stamp(k.starts_at)}`, `DTEND:${stamp(k.ends_at)}`,
      `SUMMARY:${text(k.reason ? "Blocked: " + k.reason : "Blocked")}`, "TRANSP:OPAQUE", "END:VEVENT");
  }
  lines.push("END:VCALENDAR");

  return new Response(lines.join("\r\n") + "\r\n", {
    headers: { "Content-Type": "text/calendar; charset=utf-8", "Cache-Control": "no-store" },
  });
});
