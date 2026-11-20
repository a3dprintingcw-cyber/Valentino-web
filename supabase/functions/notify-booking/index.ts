// Emails Valentino when someone books or cancels online.
// Triggered by a Supabase Database Webhook on the bookings table (insert and update).
// Secrets (Supabase > Edge Functions > Secrets):
//   RESEND_API_KEY  API key from resend.com
//   NOTIFY_EMAIL    where the emails go (Valentino's email)
//   FROM_EMAIL      optional, defaults to Resend's test sender
//   WEBHOOK_SECRET  any long random text; the webhook must send it in the x-webhook-secret header
//   SITE_URL        optional, link to the admin page in the email

type Item = { name: string; minutes: number; price: number };
type Booking = {
  id: string; starts_at: string; ends_at: string; items: Item[]; total: number;
  name: string; phone: string; notes: string | null; status: string; source: string;
};

const fmt = (iso: string, opts: Intl.DateTimeFormatOptions) =>
  new Date(iso).toLocaleString("en-GB", { timeZone: "America/Curacao", ...opts });
const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]!));

Deno.serve(async (req) => {
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-webhook-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }

  const { type, record, old_record } = await req.json() as { type: string; record: Booking; old_record?: Booking };
  if (!record || record.source !== "online") return new Response("skip");

  let kind: "new" | "cancelled" | null = null;
  if (type === "INSERT" && record.status === "booked") kind = "new";
  if (type === "UPDATE" && old_record?.status === "booked" && record.status === "cancelled") kind = "cancelled";
  if (!kind) return new Response("skip");

  const day = fmt(record.starts_at, { weekday: "long", day: "numeric", month: "long" });
  const time = fmt(record.starts_at, { hour: "2-digit", minute: "2-digit", hour12: false });
  const end = fmt(record.ends_at, { hour: "2-digit", minute: "2-digit", hour12: false });
  const services = (record.items || []).map((i) => i.name).join(", ");
  const digits = record.phone.replace(/\D/g, "");
  const wa = `https://wa.me/${digits.length <= 7 ? "5999" + digits : digits}`;
  const site = Deno.env.get("SITE_URL");

  const subject = kind === "new"
    ? `New booking: ${record.name}, ${day.split(" ").slice(0, 2).join(" ")} ${time}`
    : `Cancelled: ${record.name}, ${day.split(" ").slice(0, 2).join(" ")} ${time}`;

  const html = `
  <div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;background:#0c0c0c;color:#f4f1ea;padding:24px;border-radius:12px">
    <h2 style="color:#c9a25a;margin:0 0 12px">${kind === "new" ? "New booking" : "Booking cancelled"}</h2>
    <table style="width:100%;font-size:15px;color:#f4f1ea">
      <tr><td style="color:#a9a49a;padding:4px 0">Day</td><td>${esc(day)}</td></tr>
      <tr><td style="color:#a9a49a;padding:4px 0">Time</td><td>${time} to ${end}</td></tr>
      <tr><td style="color:#a9a49a;padding:4px 0">Name</td><td>${esc(record.name)}</td></tr>
      <tr><td style="color:#a9a49a;padding:4px 0">Phone</td><td><a style="color:#e2c487" href="${wa}">${esc(record.phone)}</a></td></tr>
      <tr><td style="color:#a9a49a;padding:4px 0">Services</td><td>${esc(services)}</td></tr>
      <tr><td style="color:#a9a49a;padding:4px 0">Total</td><td>Cg. ${record.total}</td></tr>
      ${record.notes ? `<tr><td style="color:#a9a49a;padding:4px 0">Note</td><td>${esc(record.notes)}</td></tr>` : ""}
    </table>
    ${site ? `<p style="margin-top:18px"><a style="color:#e2c487" href="${site.replace(/\/$/, "")}/admin.html">Open the agenda</a></p>` : ""}
  </div>`;

  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: Deno.env.get("FROM_EMAIL") || "Valentino Bookings <onboarding@resend.dev>",
      to: [Deno.env.get("NOTIFY_EMAIL")],
      subject,
      html,
    }),
  });
  if (!r.ok) return new Response(`email failed: ${await r.text()}`, { status: 502 });
  return new Response("sent");
});
