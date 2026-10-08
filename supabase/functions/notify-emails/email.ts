// KLUB notification emails (Slovak): new chat message, pair request, pair accepted.
// Preview locally: deno run -A supabase/functions/notify-emails/preview.ts

import { escapeHtml, layout, link } from "../_shared/email-layout.ts";
import type { Email } from "../_shared/smartemailing.ts";

export const SENDER_NAME = "KLUB O DEKÁDU MLADŠIA";
export const KINDS = ["message", "pair_request", "pair_accepted"] as const;
export type Kind = typeof KINDS[number];

export type Notification = {
  kind: Kind;
  to: string;
  recipientName: string | null; // greeting; null → "Ahoj,"
  actorName: string;
  ref: string; // pair_requests.id (= chat id for messages)
  baseUrl: string; // https://klub.trenerzien.sk
};

type Copy = {
  subject: string;
  eyebrow: string;
  headline: string;
  accent: string;
  body: string; // after the greeting; {actor} is replaced (escaped in HTML)
  button: string;
  path: string;
};

function copy(kind: Kind, ref: string): Copy {
  switch (kind) {
    case "message":
      return {
        subject: "{actor} ti poslala správu",
        eyebrow: "Nová správa",
        headline: "Máš novú",
        accent: "správu.",
        body: "{actor} ti poslala správu v klube.",
        button: "Prečítať správu",
        path: `/spravy?chat=${encodeURIComponent(ref)}`,
      };
    case "pair_request":
      return {
        subject: "{actor} ti poslala žiadosť o parťáčku",
        eyebrow: "Žiadosť o parťáčku",
        headline: "Chce byť tvojou",
        accent: "parťáčkou.",
        body: "{actor} ti poslala žiadosť o parťáčku. Pozri sa na ňu a rozhodni sa.",
        button: "Zobraziť žiadosť",
        path: "/partacky",
      };
    case "pair_accepted":
      return {
        subject: "{actor} prijala tvoju žiadosť o parťáčku",
        eyebrow: "Máš parťáčku",
        headline: "Teraz ste",
        accent: "parťáčky.",
        body: "{actor} prijala tvoju žiadosť o parťáčku. Odteraz si môžete písať správy.",
        button: "Otvoriť parťáčky",
        path: "/partacky",
      };
  }
}

export function notificationEmail(n: Notification): Email {
  const c = copy(n.kind, n.ref);
  const name = n.recipientName?.trim();
  const greeting = name ? `Ahoj ${name},` : "Ahoj,";
  const url = `${n.baseUrl}${c.path}`;
  const settingsUrl = `${n.baseUrl}/profil#upozornenia`;
  const fill = (s: string, actor: string) => s.replaceAll("{actor}", actor);

  const html = layout({
    title: fill(c.subject, escapeHtml(n.actorName)),
    eyebrow: c.eyebrow,
    headline: c.headline,
    accent: c.accent,
    intro: `${escapeHtml(greeting)} ${fill(c.body, `<strong>${escapeHtml(n.actorName)}</strong>`)}`,
    button: { label: c.button, href: url },
    note: `Tieto upozornenia si môžeš vypnúť v ${link(settingsUrl, "nastaveniach profilu")}.`,
    year: new Date().getFullYear(),
  });

  const text = [
    greeting,
    "",
    fill(c.body, n.actorName),
    "",
    `${c.button}: ${url}`,
    "",
    `Upozornenia si môžeš vypnúť v nastaveniach profilu: ${settingsUrl}`,
    "",
    "KLUB trénera ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to: n.to,
    subject: fill(c.subject, n.actorName),
    html,
    text,
    tag: "klub-upozornenie",
    senderName: SENDER_NAME,
  };
}
