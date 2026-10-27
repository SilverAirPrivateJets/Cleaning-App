// Silver Air Cleaning Desk: email notifications
// Supabase Edge Function "notify-vendor". Sends email through Resend.
//
// Who gets what:
//   Vendors        new request, job moved to or away from them, changed, cancelled, reopened, Silver Air comment
//   ASM (billing)  invoice uploaded: invoice attached, button to choose Owner or Client
//   Billing contact the charge decision (Owner or Client, plus any note)
// Recipients come from the database (vendor dispatch email, and Settings > Billing emails in the app).
//
// Secrets (Supabase > Edge Functions > Secrets):
//   RESEND_API_KEY  required. From resend.com > API Keys.
//   DESK_SECRET     required. Must match notify_secret in the database (set by 02-notifications.sql).
//   EMAIL_FROM      optional. Defaults to Resend's test sender until IT verifies the silverair.com subdomain.
//   TEST_TO         optional. When set, every email goes ONLY to this address (for testing).
//   APP_URL         optional. Link to the app. Defaults to the GitHub Pages address below.
//   REPLY_TO        optional. Where replies go, e.g. dispatch@silverair.com.

const DEFAULT_APP_URL = "https://silverairprivatejets.github.io/Cleaning-App/";
const DEFAULT_FROM = "Silver Air Cleaning Desk <onboarding@resend.dev>";
const SUPABASE_URL_FALLBACK = "https://yosioojtuzvchvzdmrpt.supabase.co";
const PUBLISHABLE_KEY_FALLBACK = "sb_publishable_mhy1c4zWbhn1IYxFAEvxqA_au3Z8ARf"; // public by design, same as index.html

const BRAND = {
  name: "Silver Air",
  ink: "#121314",
  bar: "#0B0B0C",
  orange: "#FD9600",   // Silver Air Orange
  gray: "#A2A4A3",     // Light Gray 1
  muted: "#55585A",
  line: "#E4E4E1",
  bg: "#F3F3F1",
  logo: "logo-email.png", // in the GitHub repo next to index.html
  showLogo: true,
  serif: "Zodiak,Georgia,'Times New Roman',serif",
  mono: "'Suisse Intl Mono','IBM Plex Mono',Menlo,Consolas,monospace",
};

const env = (k) => {
  try { return (globalThis.Deno ? Deno.env.get(k) : globalThis.process?.env?.[k]) || ""; } catch { return ""; }
};

const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const WD = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MO = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// Job times are stored as local airport time without a zone ("2026-09-25T08:00"), so read the parts directly.
function fmt(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(s || ""));
  if (!m) return "Not set";
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return `${WD[d.getUTCDay()]} ${+m[3]} ${MO[+m[2] - 1]} ${m[4]}:${m[5]}`;
}
function money(n) {
  if (n === null || n === undefined || n === "" || isNaN(+n)) return "";
  return "$" + (+n).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}
const cap = (s) => String(s || "").charAt(0).toUpperCase() + String(s || "").slice(1);

const HEADLINE = {
  new: "New cleaning request",
  assigned: "A cleaning was sent to you",
  removed: "A cleaning was moved to another vendor",
  cancelled: "Cleaning cancelled",
  reopened: "Cleaning reopened",
  changed: "Cleaning details changed",
  comment: "New message from Silver Air",
  invoice: "Who should be charged?",
  charge: "",
};
const INTRO = {
  new: "Silver Air has requested a cleaning from your team. Please open the Cleaning Desk to accept or decline it.",
  assigned: "Silver Air has sent this cleaning to your team. Please open the Cleaning Desk to accept or decline it.",
  removed: "Silver Air has moved this cleaning to another vendor. No action is needed from your team.",
  cancelled: "Silver Air has cancelled this cleaning. No action is needed from your team.",
  reopened: "Silver Air has reopened this cleaning. Please open the Cleaning Desk to accept or decline it.",
  changed: "Silver Air has updated the details of this cleaning. Please review the new information below.",
  comment: "Silver Air posted a message on this cleaning.",
};

export function buildEmail(m, appUrl) {
  const kind = HEADLINE[m.kind] !== undefined ? m.kind : "changed";
  const billing = kind === "invoice" || kind === "charge";
  const where = [m.airport, m.fbo].filter(Boolean).join(" · ");
  const services = Array.isArray(m.services) ? m.services.join(", ") : "";
  const replaced = /^Replaced invoice/.test(m.message || "");
  const chargeTo = m.charge && m.charge.to ? cap(m.charge.to) : "";

  let headline = HEADLINE[kind];
  let greeting = `Hi ${m.vendorName || "there"},`;
  let intro = INTRO[kind] || "";
  let subject;
  let extra = "";
  let extraBy = "";
  let button = { label: "Open the Cleaning Desk", href: appUrl };
  let footer = "Sign in with your company passcode. You're getting this because Silver Air has you listed as a cleaning vendor.";

  if (kind === "invoice") {
    greeting = "Hi ASM team,";
    intro = `${m.vendorName || "The vendor"} ${replaced ? "replaced the invoice for" : "uploaded an invoice for"} this cleaning. Please choose whether the aircraft owner or the client should be charged. The invoice is attached.`;
    subject = `Who should be charged? ${m.tail || "Aircraft"} cleaning, invoice #${m.invoiceNo || ""}${m.invoiceAmount != null ? " · " + money(m.invoiceAmount) : ""}`;
    button = { label: "Choose Owner or Client", href: m.token ? `${appUrl}?charge=${encodeURIComponent(m.token)}` : appUrl };
    footer = "The button opens a private page for this job only. No passcode needed. If someone already answered, the page shows their choice.";
  } else if (kind === "charge") {
    headline = `Charge the ${chargeTo ? chargeTo.toLowerCase() : "owner or client"}`;
    greeting = "Hi,";
    intro = `${m.charge && m.charge.by ? m.charge.by : "ASM"} decided who should be charged for this cleaning.`;
    subject = `Charge ${chargeTo || "decision"}: ${m.tail || "Aircraft"} cleaning, invoice #${m.invoiceNo || ""}${m.invoiceAmount != null ? " · " + money(m.invoiceAmount) : ""}`;
    extra = `Charge to: ${chargeTo}${m.charge && m.charge.note ? `\nNote: ${m.charge.note}` : ""}`;
    extraBy = m.charge && m.charge.by ? `${m.charge.by}${m.charge.via === "app" ? ", in the app" : ", ASM"}` : "";
    footer = "You're getting this because you're listed as the billing contact in the Cleaning Desk settings.";
  } else {
    subject = `${headline}: ${m.tail || "Aircraft"}${m.airport ? " at " + m.airport : ""}, ${fmt(m.start)}`;
    if (kind === "comment" && m.message) { extra = m.message; extraBy = m.by ? `${m.by}, Silver Air` : ""; }
    else if (kind === "cancelled" && m.message && /: /.test(m.message)) extra = m.message.replace(/^Cancelled:\s*/, "Reason: ");
    else if (kind === "changed" && m.message) extra = m.message.replace(/^Updated details:?\s*/, "") || "";
  }

  const rows = [
    ["Aircraft", [m.tail, m.aircraft].filter(Boolean).join(" · ")],
    ["Airport / FBO", where],
    [billing ? "Cleaning window" : "Available from", billing ? `${fmt(m.start)} to ${fmt(m.due)}` : fmt(m.start) + " local time"],
    billing ? ["Vendor", m.vendorName] : ["Complete by", fmt(m.due) + " local time"],
    ["Services", services],
    billing ? ["Invoice", [m.invoiceNo ? "#" + m.invoiceNo : "", money(m.invoiceAmount)].filter(Boolean).join(" · ")] : ["Instructions", m.notes],
    ["Reference", m.ref],
  ].filter(([, v]) => v);

  const logo = BRAND.showLogo
    ? `<img src="${esc(appUrl + BRAND.logo)}" alt="Silver Air Private Jets" width="263" height="36" style="display:block;width:263px;height:36px;border:0">`
    : `<span style="font-size:20px;font-weight:700;color:#FFFFFF;letter-spacing:.12em">SILVER AIR</span>`;

  const html = `<!doctype html><html><body style="margin:0;padding:0;background:${BRAND.bg}">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${BRAND.bg};padding:24px 12px">
<tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;border-radius:8px;overflow:hidden;font-family:Arial,Helvetica,sans-serif;color:${BRAND.ink}">
<tr><td style="background:${BRAND.bar};padding:20px 24px;border-bottom:3px solid ${BRAND.orange}">${logo}<div style="font-family:${BRAND.mono};font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:${BRAND.gray};margin-top:10px">Cleaning Desk</div></td></tr>
<tr><td style="padding:24px 24px 8px">
  <div style="font-family:${BRAND.serif};font-size:26px;font-weight:500;line-height:1.2;margin:0 0 10px">${esc(headline)}</div>
  <div style="font-size:15px;line-height:1.5;color:${BRAND.muted}">${esc(greeting)} ${esc(intro)}</div>
</td></tr>
${extra ? `<tr><td style="padding:12px 24px 0"><div style="background:#FFF6E8;border:1px solid ${BRAND.line};border-left:4px solid ${BRAND.orange};border-radius:4px;padding:12px 14px;font-size:15px;line-height:1.5;white-space:pre-wrap">${esc(extra)}${extraBy ? `<div style="font-size:13px;color:${BRAND.muted};margin-top:6px">${esc(extraBy)}</div>` : ""}</div></td></tr>` : ""}
<tr><td style="padding:16px 24px 4px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="font-size:14px;line-height:1.45">
${rows.map(([k, v]) => `<tr><td style="padding:8px 12px 8px 0;font-family:${BRAND.mono};font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:${BRAND.muted};white-space:nowrap;vertical-align:top;border-top:1px solid ${BRAND.line}">${esc(k)}</td><td style="padding:8px 0;border-top:1px solid ${BRAND.line};white-space:pre-wrap">${esc(v)}</td></tr>`).join("")}
</table>
</td></tr>
<tr><td style="padding:18px 24px 26px">
  <a href="${esc(button.href)}" style="display:inline-block;background:${BRAND.orange};color:${BRAND.ink};text-decoration:none;font-family:${BRAND.mono};font-weight:600;font-size:14px;letter-spacing:.04em;padding:12px 22px;border-radius:4px">${esc(button.label)}</a>
  <div style="font-size:12px;color:${BRAND.muted};margin-top:14px">${esc(footer)}</div>
</td></tr>
</table>
</td></tr></table></body></html>`;

  const text = [
    headline,
    "",
    `${greeting} ${intro}`,
    extra ? `\n${extra}${extraBy ? `\n(${extraBy})` : ""}\n` : "",
    ...rows.map(([k, v]) => `${k}: ${v}`),
    "",
    `${button.label}: ${button.href}`,
    footer,
  ].join("\n");

  return { subject, html, text };
}

export function recipients(emails) {
  return String(emails || "")
    .split(/[,;\s]+/)
    .map((e) => e.trim())
    .filter((e) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e));
}

// Fetch the invoice file so it can be attached to the ASM email. Returns null if anything goes wrong.
async function invoiceAttachment(jobId, secret) {
  try {
    const base = env("SUPABASE_URL") || SUPABASE_URL_FALLBACK;
    const key = env("SUPABASE_ANON_KEY") || PUBLISHABLE_KEY_FALLBACK;
    const r = await fetch(`${base}/rest/v1/rpc/desk_notify_invoice`, {
      method: "POST",
      headers: { apikey: key, "Content-Type": "application/json" },
      body: JSON.stringify({ p_secret: secret, p_job: jobId }),
    });
    if (!r.ok) return null;
    const f = await r.json();
    if (!f || !f.data) return null;
    const content = String(f.data).replace(/^data:[^;]+;base64,/, "");
    let name = String(f.name || "invoice").replace(/[\\/:*?"<>|]+/g, "_");
    const ext = f.mime === "application/pdf" ? ".pdf" : f.mime === "image/png" ? ".png" : f.mime === "image/webp" ? ".webp" : ".jpg";
    if (!/\.[a-z0-9]{2,5}$/i.test(name)) name += ext;
    return { filename: name, content };
  } catch {
    return null;
  }
}

async function handler(req) {
  if (req.method !== "POST") return new Response("ok");
  const secret = env("DESK_SECRET");
  if (!secret || req.headers.get("x-desk-secret") !== secret) return new Response("forbidden", { status: 403 });
  const key = env("RESEND_API_KEY");
  if (!key) return new Response("RESEND_API_KEY is not set", { status: 500 });

  let body;
  try { body = await req.json(); } catch { return new Response("bad json", { status: 400 }); }
  const appUrl = env("APP_URL") || DEFAULT_APP_URL;
  const from = env("EMAIL_FROM") || DEFAULT_FROM;
  const testTo = env("TEST_TO");
  const replyTo = env("REPLY_TO");

  const results = [];
  for (const m of body.messages || []) {
    const to = testTo ? recipients(testTo) : recipients(m.emails);
    if (!to.length) { results.push({ kind: m.kind, skipped: "no email" }); continue; }
    const { subject, html, text } = buildEmail(m, appUrl);
    const label = m.kind === "invoice" ? "ASM" : m.kind === "charge" ? "billing contact" : m.vendorName;
    const payload = { from, to, subject: testTo ? `[TEST for ${label}] ${subject}` : subject, html, text };
    if (replyTo) payload.reply_to = replyTo;
    if (m.kind === "invoice" && m.hasInvoice) {
      const att = await invoiceAttachment(m.jobId, secret);
      if (att) payload.attachments = [att];
    }
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      results.push({ kind: m.kind, to, status: r.status, attached: !!payload.attachments, response: await r.text() });
    } catch (e) {
      results.push({ kind: m.kind, to, error: String(e) });
    }
  }
  console.log(JSON.stringify(results));
  return new Response(JSON.stringify({ results }), { headers: { "Content-Type": "application/json" } });
}

if (globalThis.Deno) Deno.serve(handler);
export { handler };
