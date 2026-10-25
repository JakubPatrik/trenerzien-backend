// Booking emails (Slovak) sent via SmartEmailing — to the lead, to the helper
// (with the questionnaire answers) and to the owner (who booked with whom, with
// the answers) — styled like the booking page's confirmation step. The lead and
// helper emails carry the calendar invite as pozvanka.ics (METHOD:REQUEST, so mail
// clients show their native event card); the owner already has Google's invite
// (see _shared/booking.ts).
// Double opt-in (BOOKING_OPT_IN.md): optInEmail asks the lead to confirm her email
// before any of the above is sent; nudgeEmail tells the owner to call her when the
// hold expired or the confirmation email could not be sent.
// Preview locally: deno run -A supabase/functions/book-meeting/preview.ts

import { escapeHtml, firstName, layout, link } from "./email-layout.ts";
import type { Email } from "./smartemailing.ts";
import { answerHtml, answers, type Answers, vitals } from "./application.ts";
import { buildIcs } from "./ics.ts";

// Sender (and reply-to) of all booking emails; must be a confirmed sender in SmartEmailing.
const SENDER_EMAIL = "pohovory@trenerzien.sk";

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
  lead: { name: string; email: string; phone: string; answers: Answers };
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
      organizer: { email: d.organizerEmail ?? SENDER_EMAIL, name: "Tréner ŽIEN" },
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
    senderEmail: SENDER_EMAIL,
    attachments: [
      invite(d, { email: d.lead.email, name: d.lead.name }, `Pohovor Tréner ŽIEN × ${d.helper.name}`, [
        "Účasť je záväzná. Tešíme sa!",
      ]),
    ],
  };
}

// Lead's contact as [label, HTML] rows and plain-text lines.
function contact(lead: { name: string; email: string; phone: string }) {
  const rows: [string, string][] = [
    ["Klientka", escapeHtml(lead.name)],
    ["E-mail", link(`mailto:${lead.email}`, lead.email)],
  ];
  if (lead.phone) rows.push(["Telefón", link(`tel:${lead.phone.replace(/\s+/g, "")}`, lead.phone)]);
  const text = [`Klientka: ${lead.name}`, `E-mail: ${lead.email}`, ...(lead.phone ? [`Telefón: ${lead.phone}`] : [])];
  return { rows, text };
}

// The questionnaire under the call summary: vek / mesto / váha first, then the free-text answers.
function questionnaire(a: Answers) {
  const all = [...vitals(a), ...answers(a)];
  return {
    html: all.map(([question, answer]): [string, string] => [question, answerHtml(answer)]),
    text: all.length ? ["", "ODPOVEDE Z DOTAZNÍKA", ...all.flatMap(([q, answer]) => ["", `${q}:`, answer])] : [],
  };
}

// To the helper who runs the call.
export function helperEmail(d: BookingData): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const e = escapeHtml;
  const lead = contact(d.lead);
  const q = questionnaire(d.lead.answers);

  const html = layout({
    title: "Nový pohovor",
    eyebrow: "Nový pohovor",
    headline: "Máš nový",
    accent: "pohovor.",
    intro: `Ahoj ${e(firstName(d.helper.name))}, ${e(firstName(d.lead.name))} si rezervovala termín s tebou.`,
    rows: [["Dátum", e(day)], ["Čas", e(time)], ...lead.rows],
    answersTitle: "Odpovede z dotazníka",
    answers: q.html,
    note: "Pred pohovorom sa prosím telefonicky spoj s klientkou a potvrď si rezerváciu.",
    button: { label: "Pripojiť sa na pohovor", href: d.meetLink },
    year: d.start.getFullYear(),
  });

  const text = [
    `Ahoj ${firstName(d.helper.name)},`,
    "",
    "máš nový pohovor.",
    "",
    `Dátum: ${day}`,
    `Čas: ${time}`,
    ...lead.text,
    `Pripojiť sa na pohovor: ${d.meetLink}`,
    ...q.text,
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
    senderEmail: SENDER_EMAIL,
    attachments: [invite(d, { email: d.helper.email, name: d.helper.name }, `Pohovor: ${d.lead.name}`, lead.text)],
  };
}

// To the owner (pohovory@): who booked with whom, the answers and the Meet link.
// No .ics — the owner already gets Google's own invite.
export function ownerEmail(d: BookingData, to: string): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const e = escapeHtml;
  const lead = contact(d.lead);
  const q = questionnaire(d.lead.answers);

  const html = layout({
    title: `Rezervovaný pohovor: ${e(d.lead.name)}`,
    eyebrow: "Rezervovaný pohovor",
    headline: "Nový pohovor",
    accent: "v kalendári.",
    intro: `<strong>${e(d.lead.name)}</strong> si rezervovala pohovor s personalistkou <strong>${e(d.helper.name)}</strong>.`,
    rows: lead.rows,
    moreRows: {
      divider: "má pohovor s",
      rows: [
        ["Personalistka", e(d.helper.name)],
        ["E-mail", link(`mailto:${d.helper.email}`, d.helper.email)],
        ["Dátum", e(day)],
        ["Čas", e(time)],
      ],
    },
    answersTitle: "Odpovede z dotazníka",
    answers: q.html,
    note: "Pozvánku s Meet linkom máš aj v Google Kalendári. Klientka aj personalistka dostali potvrdenie e-mailom.",
    button: { label: "Pripojiť sa k hovoru", href: d.meetLink },
    year: d.start.getFullYear(),
  });

  const text = [
    `Rezervovaný pohovor: ${d.lead.name} × ${d.helper.name}`,
    "",
    ...lead.text,
    "— má pohovor s —",
    `Personalistka: ${d.helper.name} (${d.helper.email})`,
    `Dátum: ${day}`,
    `Čas: ${time}`,
    `Google Meet: ${d.meetLink}`,
    ...q.text,
    "",
    "Pozvánku s Meet linkom máš aj v Google Kalendári. Klientka aj personalistka dostali potvrdenie e-mailom.",
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to,
    subject: `Rezervovaný pohovor: ${d.lead.name} × ${d.helper.name}, ${day}, ${time}`,
    html,
    text,
    tag: "booking-owner",
    senderEmail: SENDER_EMAIL,
  };
}

// "14:30" in the booking time zone.
export function formatTime(d: Date, timeZone: string): string {
  return new Intl.DateTimeFormat("sk-SK", { timeZone, hour: "numeric", minute: "2-digit" }).format(d);
}

export type OptInData = {
  start: Date;
  end: Date;
  timeZone: string;
  expiresAt: Date; // end of the hold
  link: string; // /pohovor/dakujem?t=<opt_in_token>
  lead: { name: string; email: string };
  helper: { name: string };
};

// To the lead right after she picked a time: confirm the email, then the invitation follows.
export function optInEmail(d: OptInData): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const until = formatTime(d.expiresAt, d.timeZone);
  const e = escapeHtml;
  const html = layout({
    title: "Potvrď svoj e-mail",
    eyebrow: "Ešte jeden krok",
    headline: "Potvrď svoj",
    accent: "e-mail.",
    intro: `Ahoj ${e(firstName(d.lead.name))}, termín ti držíme do <strong>${e(until)}</strong>. ` +
      "Pozvánku na pohovor ti pošleme hneď, ako potvrdíš svoj e-mail.",
    rows: [["Dátum", e(day)], ["Čas", e(time)], ["S kým", e(d.helper.name)]],
    note: `Ak e-mail do ${e(until)} nepotvrdíš, termín sa uvoľní. ` +
      "Ak si sa na pohovor neprihlasovala, tento e-mail ignoruj.",
    button: { label: "Potvrdiť e-mail", href: d.link },
    year: d.start.getFullYear(),
  });

  const text = [
    `Ahoj ${firstName(d.lead.name)},`,
    "",
    `termín ti držíme do ${until}. Pozvánku na pohovor ti pošleme hneď, ako potvrdíš svoj e-mail:`,
    d.link,
    "",
    `Dátum: ${day}`,
    `Čas: ${time}`,
    `S kým: ${d.helper.name}`,
    "",
    `Ak e-mail do ${until} nepotvrdíš, termín sa uvoľní. Ak si sa na pohovor neprihlasovala, tento e-mail ignoruj.`,
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to: d.lead.email,
    subject: `Potvrď e-mail k pohovoru: ${day}, ${time}`,
    html,
    text,
    tag: "booking-opt-in",
    senderEmail: SENDER_EMAIL,
  };
}

export type NudgeData = {
  reason: "expired" | "email_failed";
  start: Date;
  end: Date;
  timeZone: string;
  expiresAt: Date;
  lead: { name: string; email: string; phone: string | null };
  helper: { name: string };
};

// To the owner (pohovory@): the lead never confirmed (or never got) the email — call her.
export function nudgeEmail(d: NudgeData, to: string): Email {
  const { day, time } = formatSlot(d.start, d.end, d.timeZone);
  const until = formatTime(d.expiresAt, d.timeZone);
  const e = escapeHtml;
  const lead = contact({ ...d.lead, phone: d.lead.phone ?? "" });
  const expired = d.reason === "expired";
  const intro = expired
    ? `<strong>${e(d.lead.name)}</strong> si vybrala termín, ale do ${e(until)} nepotvrdila e-mail. ` +
      "Termín sa uvoľnil. Zavolaj jej, over e-mail a dohodnite nový termín."
    : `Potvrdzovací e-mail pre <strong>${e(d.lead.name)}</strong> sa nepodarilo odoslať (možno preklep v adrese). ` +
      `Termín jej držíme do ${e(until)}. Zavolaj jej a over e-mail.`;
  const note = expired
    ? "Leadka nedostala pozvánku na pohovor ani Meet link. Personalistka o termíne nevie."
    : "Správny e-mail pošli podpore (podpora@trenerzien.sk), pošle jej nový odkaz.";
  const phone = d.lead.phone?.replace(/\s+/g, "");

  const html = layout({
    title: `Nepotvrdený termín: ${e(d.lead.name)}`,
    eyebrow: expired ? "Nepotvrdený termín" : "E-mail neodišiel",
    headline: "Treba",
    accent: "zavolať.",
    intro,
    rows: lead.rows,
    moreRows: {
      divider: "chcela termín",
      rows: [["Personalistka", e(d.helper.name)], ["Dátum", e(day)], ["Čas", e(time)]],
    },
    note,
    button: phone
      ? { label: "Zavolať klientke", href: `tel:${phone}` }
      : { label: "Napísať klientke", href: `mailto:${d.lead.email}` },
    year: d.start.getFullYear(),
  });

  const text = [
    expired ? `Nepotvrdený termín: ${d.lead.name}` : `E-mail neodišiel: ${d.lead.name}`,
    "",
    expired
      ? `Do ${until} nepotvrdila e-mail, termín sa uvoľnil. Zavolaj jej, over e-mail a dohodnite nový termín.`
      : `Potvrdzovací e-mail sa nepodarilo odoslať. Termín jej držíme do ${until}. Zavolaj jej a over e-mail.`,
    "",
    ...lead.text,
    "— chcela termín —",
    `Personalistka: ${d.helper.name}`,
    `Dátum: ${day}`,
    `Čas: ${time}`,
    "",
    expired
      ? "Leadka nedostala pozvánku na pohovor ani Meet link. Personalistka o termíne nevie."
      : "Správny e-mail pošli podpore (podpora@trenerzien.sk), pošle jej nový odkaz.",
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to,
    subject: `${expired ? "Nepotvrdený termín" : "E-mail neodišiel"}: ${d.lead.name}, ${day}, ${time}`,
    html,
    text,
    tag: "booking-nudge",
    senderEmail: SENDER_EMAIL,
  };
}
