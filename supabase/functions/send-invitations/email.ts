// Invitation to KLUB (Slovak): link to /nove-heslo where the member sets her password.
// Preview locally: deno run -A supabase/functions/send-invitations/preview.ts

import { escapeHtml, layout, link } from "../_shared/email-layout.ts";
import type { Email } from "../_shared/smartemailing.ts";

export const SENDER_NAME = "KLUB trénera ŽIEN";

export function inviteEmail(d: { to: string; fullName: string; inviteUrl: string }): Email {
  const name = d.fullName.trim();
  const greeting = name ? `Ahoj ${name},` : "Ahoj,";

  const html = layout({
    title: "Nastav si heslo do klubu",
    eyebrow: "KLUB trénera ŽIEN",
    headline: "Vitaj v",
    accent: "klube.",
    intro: `${escapeHtml(greeting)} tvoj prístup do <strong>KLUBU trénera ŽIEN</strong> je pripravený. Zostáva si nastaviť heslo.`,
    button: { label: "Nastaviť heslo", href: d.inviteUrl },
    note: `Odkaz platí 7 dní. Ak tlačidlo nefunguje, otvor ${link(d.inviteUrl, "tento odkaz")}.
        Ak si o prístup nežiadala, e-mail jednoducho ignoruj.`,
    year: new Date().getFullYear(),
  });

  const text = [
    greeting,
    "",
    "tvoj prístup do KLUBU trénera ŽIEN je pripravený. Zostáva si nastaviť heslo:",
    d.inviteUrl,
    "",
    "Odkaz platí 7 dní. Ak si o prístup nežiadala, e-mail jednoducho ignoruj.",
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to: d.to,
    subject: "Nastav si heslo do KLUBU trénera ŽIEN",
    html,
    text,
    tag: "klub-nastavenie-hesla",
    senderName: SENDER_NAME,
  };
}
