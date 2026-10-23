// Consultation reminder email (Slovak), sent to club members on the morning of a consultation.
// Preview locally: deno run -A supabase/functions/consultation-reminder/preview.ts

import { escapeHtml, layout, link } from "../_shared/email-layout.ts";
import type { Email } from "../_shared/smartemailing.ts";

export const SENDER_NAME = "Klub o dekádu mladšia";
export const ZOOM_URL = "https://zoom.us/j/93635373091?pwd=dmxUeExLamtsSzRNQkQvYlJIRjczUT09"; // same for every session

export type Reminder = {
  to: string;
  recipientName: string | null; // greeting; null → "Ahoj,"
  startsAt: Date;
  timeZone: string; // Europe/Bratislava
  baseUrl: string; // https://klub.trenerzien.sk
};

// { day: "Streda 21. októbra", time: "19:00" }
function formatStart(start: Date, timeZone: string): { day: string; time: string } {
  const day = new Intl.DateTimeFormat("sk-SK", { timeZone, weekday: "long", day: "numeric", month: "long" })
    .format(start).replace(/,/g, "");
  const time = new Intl.DateTimeFormat("sk-SK", { timeZone, hour: "numeric", minute: "2-digit" }).format(start);
  return { day: day.charAt(0).toUpperCase() + day.slice(1), time };
}

export function reminderEmail(r: Reminder): Email {
  const { day, time } = formatStart(r.startsAt, r.timeZone);
  const name = r.recipientName?.trim();
  const greeting = name ? `Ahoj ${name},` : "Ahoj,";
  const consultationsUrl = `${r.baseUrl}/konzultacie`;
  const settingsUrl = `${r.baseUrl}/profil#upozornenia`;
  const subject = `Dnes o ${time} konzultácia s Danielom na ZOOM`;

  const html = layout({
    title: escapeHtml(subject),
    eyebrow: "Konzultácia s Danielom",
    headline: "Dnes o",
    accent: `${time}.`,
    intro: `${escapeHtml(greeting)} dnes máme ďalšiu konzultáciu. ` +
      "<strong>Ak potrebuješ niečo prekonzultovať, som tu pre teba.</strong>",
    rows: [["Kedy", `Dnes · ${escapeHtml(day)}`], ["Čas", time], ["Kde", "ZOOM (online)"]],
    button: { label: "Pripojiť sa na ZOOM", href: ZOOM_URL },
    note: "Stačí sa pripojiť v čase konzultácie cez tlačidlo vyššie. Otázku môžeš vložiť aj vopred " +
      `v ${link(consultationsUrl, "sekcii Konzultácie")} — odpovedám na ne postupne naživo.<br><br>` +
      "Teším sa na teba! Vidíme sa :) Daniel<br><br>" +
      `<span style="font-size:13px;color:#6B6B6B;">Pripomienky konzultácií si môžeš vypnúť v ${
        link(settingsUrl, "nastaveniach profilu")
      }.</span>`,
    year: r.startsAt.getFullYear(),
  });

  const text = [
    greeting,
    "",
    "dnes máme ďalšiu konzultáciu. Ak potrebuješ niečo prekonzultovať, som tu pre teba.",
    "",
    `Kedy: dnes, ${day} o ${time}`,
    "Kde: ZOOM (online)",
    "",
    `Stačí sa pripojiť v čase konzultácie cez tento odkaz: ${ZOOM_URL}`,
    `Otázku môžeš vložiť aj vopred v sekcii Konzultácie: ${consultationsUrl}`,
    "",
    "Teším sa na teba! Vidíme sa :) Daniel",
    "",
    `Pripomienky konzultácií si môžeš vypnúť v nastaveniach profilu: ${settingsUrl}`,
    "",
    "KLUB trénera ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return { to: r.to, subject, html, text, tag: "klub-konzultacia", senderName: SENDER_NAME };
}
