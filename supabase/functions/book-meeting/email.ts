// Booking emails (Slovak) sent via SmartEmailing — one to the lead, one to the
// helper — styled like the booking page's confirmation step. Each carries the
// calendar invite as pozvanka.ics (METHOD:REQUEST, so mail clients show their
// native event card). Google emails only the owner (see book-meeting/index.ts).
// Preview locally: deno run -A supabase/functions/book-meeting/preview.ts

import { escapeHtml, firstName, layout, link } from "../_shared/email-layout.ts";
import type { Email } from "../_shared/smartemailing.ts";
import { buildIcs } from "./ics.ts";

const SUPPORT_EMAIL = "podpora@trenerzien.sk";

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
    button: { label: "Pripojiť sa k hovoru", href: d.meetLink },
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
    button: { label: "Pripojiť sa na pohovor", href: d.meetLink },
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
