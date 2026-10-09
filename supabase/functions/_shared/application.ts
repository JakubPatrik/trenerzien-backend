// The consultation_applications questionnaire as shown in the booking emails to
// the helper and the owner.

import { escapeHtml } from "./email-layout.ts";

// A consultation_applications row (the questionnaire columns).
export type Answers = {
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
};

export const ANSWER_COLUMNS =
  "age, current_weight, target_weight, health_issues, occupation, hobbies, genetics, life_changes, obstacles, vision_one_year, expectations";

// Questionnaire order; empty answers are left out.
const QUESTIONS: [keyof Answers, string][] = [
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
export function weight(a: Answers): string | null {
  const now = a.current_weight != null ? kg(a.current_weight) : null;
  const target = a.target_weight != null ? kg(a.target_weight) : null;
  if (now && target) return `${now} → ${target}`;
  return now ?? (target && `cieľ ${target}`);
}

// Vek / Váha as [label, plain text]; missing ones are left out.
export function vitals(a: Answers): [string, string][] {
  const w = weight(a);
  return [
    ...(a.age != null ? [["Vek", String(a.age)] as [string, string]] : []),
    ...(w ? [["Váha", w] as [string, string]] : []),
  ];
}

// Free-text answers as [question, plain text].
export function answers(a: Answers): [string, string][] {
  return QUESTIONS
    .map(([key, question]) => [question, (a[key] as string | null)?.trim() ?? ""] as [string, string])
    .filter(([, answer]) => answer);
}

// Plain-text answer → HTML for the layout's answer block.
export const answerHtml = (s: string) => escapeHtml(s.trim()).replace(/\r?\n/g, "<br>");
