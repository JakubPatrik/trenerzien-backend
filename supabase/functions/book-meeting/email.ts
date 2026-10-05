// Booking emails (Slovak) sent via SmartEmailing — one to the lead, one to the
// helper — styled like the booking page's confirmation step. Each carries the
// calendar invite as pozvanka.ics (METHOD:REQUEST, so mail clients show their
// native event card). Google emails only the owner (see book-meeting/index.ts).
// Preview locally: deno run -A supabase/functions/book-meeting/preview.ts

import type { Email } from "../_shared/smartemailing.ts";
import { buildIcs } from "./ics.ts";

const RED = "#B8292F";
const INK = "#0B0B0D";
const MUTED = "#6B6B6B";
const LINE = "#E2E2E2";
const SUPPORT_EMAIL = "podpora@trenerzien.sk";

// Web fonts where the client supports them (Apple Mail, iOS), safe fallbacks elsewhere (Gmail).
const FONT_DISPLAY = "'Bebas Neue','Oswald','Arial Narrow',Impact,sans-serif";
const FONT_SERIF = "'Playfair Display',Georgia,'Times New Roman',serif";
const FONT_MONO = "'JetBrains Mono','Courier New',monospace";
const FONT_SANS = "Inter,Arial,Helvetica,sans-serif";

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

// { day: "Utorok 6. októbra", time: "10:00–11:00" }
export function formatSlot(start: Date, end: Date, timeZone: string): { day: string; time: string } {
  const day = new Intl.DateTimeFormat("sk-SK", { timeZone, weekday: "long", day: "numeric", month: "long" })
    .format(start).replace(/,/g, "");
  const time = new Intl.DateTimeFormat("sk-SK", { timeZone, hour: "numeric", minute: "2-digit" });
  return { day: day.charAt(0).toUpperCase() + day.slice(1), time: `${time.format(start)}–${time.format(end)}` };
}

export type BookingData = {
  eventId: string; // Google event id
  organizerEmail: string | null; // Google calendar account; the invite's ORGANIZER
  start: Date;
  end: Date;
  timeZone: string;
  meetLink: string;
  lead: { name: string; email: string; phone: string };
  helper: { name: string; email: string };
};

const firstName = (name: string) => name.trim().split(/\s+/)[0] || name;

type Layout = {
  title: string;
  eyebrow: string;
  headline: string; // HTML: plain words, then the italic accent word
  accent: string;
  intro: string; // HTML
  rows: [label: string, value: string][]; // HTML values
  note: string; // HTML
  button: string;
  meetLink: string;
  year: number;
};

function layout(l: Layout): string {
  const row = ([label, value]: [string, string], i: number) => {
    const border = i < l.rows.length - 1 ? `border-bottom:1px solid ${LINE};` : "";
    return `
          <tr>
            <td style="padding:18px 20px;${border}font-family:${FONT_SANS};font-size:16px;color:${MUTED};">${label}</td>
            <td align="right" style="padding:18px 20px;${border}font-family:${FONT_SANS};font-size:16px;font-weight:600;color:${INK};">${value}</td>
          </tr>`;
  };

  return `<!doctype html>
<html lang="sk"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Inter:wght@400;600&family=JetBrains+Mono&family=Playfair+Display:ital@1&display=swap" rel="stylesheet">
<title>${l.title}</title>
</head>
<body style="margin:0;padding:0;background:#F2F2F2;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2F2F2;"><tr><td align="center" style="padding:24px 12px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;border-radius:8px;overflow:hidden;">
    <tr><td align="center" style="background:${INK};padding:18px 32px;font-family:${FONT_SANS};font-size:22px;font-weight:600;letter-spacing:-0.3px;color:#FFFFFF;">
      tréner <span style="color:${RED};">ŽIEN</span>
    </td></tr>
    <tr><td style="padding:36px 32px 0;">
      <div style="font-family:${FONT_MONO};font-size:12px;letter-spacing:4px;text-transform:uppercase;color:${RED};">${l.eyebrow}</div>
      <h1 style="margin:14px 0 0;font-family:${FONT_DISPLAY};font-size:44px;line-height:1;font-weight:normal;text-transform:uppercase;color:${INK};">${l.headline} <span style="font-family:${FONT_SERIF};font-style:italic;text-transform:none;color:${RED};">${l.accent}</span></h1>
      <p style="margin:16px 0 0;font-family:${FONT_SANS};font-size:16px;line-height:1.5;color:#444;">${l.intro}</p>
    </td></tr>
    <tr><td style="padding:28px 32px 0;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ${LINE};border-collapse:separate;">
        ${l.rows.map(row).join("")}
      </table>
    </td></tr>
    <tr><td style="padding:24px 32px 0;">
      <a href="${escapeHtml(l.meetLink)}" style="display:block;background:${RED};color:#FFFFFF;text-align:center;padding:17px;font-family:${FONT_SANS};font-size:17px;font-weight:600;text-decoration:none;">${l.button}</a>
    </td></tr>
    <tr><td style="padding:24px 32px 36px;">
      <div style="border-left:3px solid ${RED};padding:2px 0 2px 16px;font-family:${FONT_SANS};font-size:15px;line-height:1.55;color:#444;">
        ${l.note}
      </div>
    </td></tr>
    <tr><td align="center" style="background:${INK};padding:20px 32px;font-family:${FONT_SANS};font-size:14px;color:#9A9A9A;">
      © ${l.year} Tréner ŽIEN · Mgr. Daniel Čmel.
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}

const link = (href: string, label: string) =>
  `<a href="${escapeHtml(href)}" style="color:${INK};font-weight:600;">${escapeHtml(label)}</a>`;

function invite(d: BookingData, to: { email: string; name: string }, summary: string, details: string[]) {
  return {
    fileName: "pozvanka.ics",
    contentType: "text/calendar",
    content: buildIcs({
      // Google's iCalUID for the event, so accepting in Google Calendar matches the existing event.
      uid: `${d.eventId}@google.com`,
      start: d.start,
      end: d.end,
      summary,
      description: [`Google Meet: ${d.meetLink}`, "", ...details].join("\n"),
      url: d.meetLink,
      organizer: { email: d.organizerEmail ?? SUPPORT_EMAIL, name: "Tréner ŽIEN" },
      attendee: to,
    }),
  };
}

// To the lead (client).
export function leadEmail(d: BookingData): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const e = escapeHtml;
  const html = layout({
    title: "Termín je potvrdený",
    eyebrow: "Termín je potvrdený",
    headline: "Tešíme sa na",
    accent: "teba.",
    intro: `Ahoj ${e(firstName(d.lead.name))}, tvoj pohovor je rezervovaný.`,
    rows: [["Dátum", e(day)], ["Čas", e(time)], ["S kým", e(d.helper.name)]],
    note: "K hovoru sa pripojíš v dohodnutom čase kliknutím na červené tlačidlo. Účasť je záväzná. Tešíme sa!",
    button: "Pripojiť sa k hovoru",
    meetLink: d.meetLink,
    year: d.start.getFullYear(),
  });

  const text = [
    `Ahoj ${firstName(d.lead.name)},`,
    "",
    "tvoj pohovor je potvrdený. Tešíme sa na teba.",
    "",
    `Dátum: ${day}`,
    `Čas: ${time}`,
    `S kým: ${d.helper.name}`,
    "",
    `K hovoru sa pripojíš v dohodnutom čase cez tento odkaz: ${d.meetLink}`,
    "Účasť je záväzná. Tešíme sa!",
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to: d.lead.email,
    subject: `Pohovor potvrdený: ${day}, ${time}`,
    html,
    text,
    tag: "booking-confirmation",
    attachments: [
      invite(d, { email: d.lead.email, name: d.lead.name }, `Pohovor Tréner ŽIEN × ${d.helper.name}`, [
        "Účasť je záväzná. Tešíme sa!",
      ]),
    ],
  };
}

// To the helper who runs the call.
export function helperEmail(d: BookingData): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const e = escapeHtml;
  const rows: [string, string][] = [
    ["Dátum", e(day)],
    ["Čas", e(time)],
    ["Klientka", e(d.lead.name)],
    ["E-mail", link(`mailto:${d.lead.email}`, d.lead.email)],
  ];
  if (d.lead.phone) rows.push(["Telefón", link(`tel:${d.lead.phone.replace(/\s+/g, "")}`, d.lead.phone)]);

  const html = layout({
    title: "Nový pohovor",
    eyebrow: "Nový pohovor",
    headline: "Máš nový",
    accent: "pohovor.",
    intro: `Ahoj ${e(firstName(d.helper.name))}, ${e(firstName(d.lead.name))} si rezervovala termín s tebou.`,
    rows,
    note: "Pred pohovorom sa prosím telefonicky spoj s klientkou a potvrď si rezerváciu.",
    button: "Pripojiť sa na pohovor",
    meetLink: d.meetLink,
    year: d.start.getFullYear(),
  });

  const contact = [`Klientka: ${d.lead.name}`, `E-mail: ${d.lead.email}`, ...(d.lead.phone ? [`Telefón: ${d.lead.phone}`] : [])];
  const text = [
    `Ahoj ${firstName(d.helper.name)},`,
    "",
    "máš nový pohovor.",
    "",
    `Dátum: ${day}`,
    `Čas: ${time}`,
    ...contact,
    `Pripojiť sa na pohovor: ${d.meetLink}`,
    "",
    "Pred pohovorom sa prosím telefonicky spoj s klientkou a potvrď si rezerváciu.",
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to: d.helper.email,
    subject: `Nový pohovor: ${d.lead.name}, ${day}, ${time}`,
    html,
    text,
    tag: "booking-helper",
    attachments: [invite(d, { email: d.helper.email, name: d.helper.name }, `Pohovor: ${d.lead.name}`, contact)],
  };
}
