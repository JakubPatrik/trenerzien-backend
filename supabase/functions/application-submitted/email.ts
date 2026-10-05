// "Nová prihláška" email (Slovak) sent via SmartEmailing to the team after a lead
// submits the questionnaire (consultation_applications). Replaces Lovable's
// nova-prihlaska React Email template.
// Preview locally: deno run -A supabase/functions/application-submitted/preview.ts

import { escapeHtml, firstName, layout, link } from "../_shared/email-layout.ts";
import type { Email } from "../_shared/smartemailing.ts";

const TIME_ZONE = "Europe/Bratislava";

// A consultation_applications row (the columns this email uses).
export type Application = {
  name: string;
  email: string;
  phone: string;
  age: number | null;
  current_weight: number | null;
  target_weight: number | null;
  health_issues: string | null;
  occupation: string | null;
  hobbies: string | null;
  genetics: string | null;
  life_changes: string | null;
  obstacles: string | null;
  vision_one_year: string | null;
  expectations: string | null;
  qualified: boolean;
  created_at: string;
};

// Questionnaire order; empty answers are left out.
const QUESTIONS: [keyof Application, string][] = [
  ["health_issues", "Zdravotné problémy"],
  ["occupation", "Zamestnanie"],
  ["hobbies", "Záľuby"],
  ["genetics", "Genetika"],
  ["life_changes", "Zmeny v živote"],
  ["obstacles", "Čo jej doteraz bránilo"],
  ["vision_one_year", "Kde sa vidí o rok"],
  ["expectations", "Čo očakáva"],
];

const kg = (n: number) => `${new Intl.NumberFormat("sk-SK", { maximumFractionDigits: 1 }).format(n)} kg`;

// "72 kg → 62 kg", or whichever side is filled in.
function weight(a: Application): string | null {
  const now = a.current_weight != null ? kg(a.current_weight) : null;
  const target = a.target_weight != null ? kg(a.target_weight) : null;
  if (now && target) return `${now} → ${target}`;
  return now ?? (target && `cieľ ${target}`);
}

// "5. októbra 2026 o 14:32"
function submittedAt(iso: string): string {
  const d = new Date(iso);
  const day = new Intl.DateTimeFormat("sk-SK", { timeZone: TIME_ZONE, day: "numeric", month: "long", year: "numeric" });
  const time = new Intl.DateTimeFormat("sk-SK", { timeZone: TIME_ZONE, hour: "numeric", minute: "2-digit" });
  return `${day.format(d)} o ${time.format(d)}`;
}

export function applicationEmail(a: Application, to: string): Email {
  const e = escapeHtml;
  const multiline = (s: string) => e(s.trim()).replace(/\r?\n/g, "<br>");
  const phone = a.phone.trim();
  const tel = `tel:${phone.replace(/\s+/g, "")}`;
  const w = weight(a);

  const details: [string, string][] = [
    ["E-mail", a.email],
    ["Telefón", phone],
    ...(a.age != null ? [["Vek", String(a.age)] as [string, string]] : []),
    ...(w ? [["Váha", w] as [string, string]] : []),
  ];
  const rows: [string, string][] = details.map(([label, value]) => [
    label,
    label === "E-mail" ? link(`mailto:${value}`, value) : label === "Telefón" ? link(tel, value) : e(value),
  ]);
  const answers = QUESTIONS
    .map(([key, question]) => [question, (a[key] as string | null)?.trim() ?? ""] as const)
    .filter(([, answer]) => answer);

  const when = submittedAt(a.created_at);
  const status = a.qualified
    ? `${e(firstName(a.name))} teraz vyberá termín pohovoru. Keď si ho rezervuje, sprievodkyňa dostane pozvánku.`
    : `${e(firstName(a.name))} podľa dotazníka <strong>nesplnila podmienky</strong>, termín pohovoru si rezervovať nemôže.`;

  const html = layout({
    title: `Nová prihláška: ${e(a.name)}`,
    eyebrow: "Nová prihláška",
    headline: "Prišla nová",
    accent: "prihláška.",
    intro: `<strong>${e(a.name)}</strong> vyplnila dotazník ${e(when)}.`,
    rows,
    answers: answers.map(([question, answer]) => [question, multiline(answer)]),
    button: { label: "Napísať klientke", href: `mailto:${a.email}` },
    note: status,
    year: new Date(a.created_at).getFullYear(),
  });

  const text = [
    `Nová prihláška: ${a.name}`,
    `Vyplnila dotazník ${when}.`,
    "",
    ...details.map(([label, value]) => `${label}: ${value}`),
    ...answers.flatMap(([question, answer]) => ["", `${question}:`, answer]),
    "",
    a.qualified
      ? `${firstName(a.name)} teraz vyberá termín pohovoru. Keď si ho rezervuje, sprievodkyňa dostane pozvánku.`
      : `${firstName(a.name)} podľa dotazníka nesplnila podmienky, termín pohovoru si rezervovať nemôže.`,
    "",
    "Tréner ŽIEN · Mgr. Daniel Čmel",
  ].join("\n");

  return {
    to,
    subject: `Nová prihláška: ${a.name}${a.qualified ? "" : " (nesplnila podmienky)"}`,
    html,
    text,
    tag: "nova-prihlaska",
  };
}
