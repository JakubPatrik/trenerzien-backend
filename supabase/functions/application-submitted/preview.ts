// Renders the "Nová prihláška" email with sample data and opens it in the browser.
// Nothing is sent. Writes the HTML and plain-text versions of a full application
// and of a sparse one that did not qualify (empty answers are left out).
//
//   deno run -A supabase/functions/application-submitted/preview.ts [out-dir]

import { type Application, applicationEmail } from "./email.ts";

const outDir = Deno.args[0] ?? await Deno.makeTempDir({ prefix: "application-email-" });
await Deno.mkdir(outDir, { recursive: true });

const full: Application = {
  name: "Jana Nováková",
  email: "jana@example.sk",
  phone: "+421 900 123 456",
  age: 38,
  current_weight: 78.5,
  target_weight: 65,
  health_issues: "Štítna žľaza (Hashimoto), užívam Letrox.",
  occupation: "Účtovníčka, 8 hodín denne v sede.",
  hobbies: "Turistika, čítanie, záhrada.",
  genetics: "Mama aj stará mama mali sklony k nadváhe.",
  life_changes: "Po druhom dieťati som pribrala 12 kg.\nPred rokom som sa presťahovala a zmenila prácu.",
  obstacles: "Nedostatok času a jojo efekt po každej diéte. Večer sa prejedám.",
  vision_one_year: "Chcem mať energiu na deti, cítiť sa dobre vo svojom tele a zabehnúť 10 km.",
  expectations: "Jasný plán, ktorý zvládnem popri rodine, a niekoho, kto ma podrží.",
  qualified: true,
  created_at: "2026-10-05T14:32:00+02:00",
};

const notQualified: Application = {
  ...full,
  name: "Petra Kováčová",
  email: "petra@example.sk",
  phone: "0911 222 333",
  age: 17,
  current_weight: 60,
  target_weight: null,
  health_issues: null,
  hobbies: "",
  genetics: null,
  life_changes: null,
  qualified: false,
};

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";

for (const [name, application] of [["qualified", full], ["not-qualified", notQualified]] as const) {
  const email = applicationEmail(application, "podpora@trenerzien.sk");
  await Deno.writeTextFile(`${outDir}/${name}.html`, email.html);
  await Deno.writeTextFile(`${outDir}/${name}.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
  console.log(`${name}: ${email.subject}`);
  await new Deno.Command(opener, { args: [`${outDir}/${name}.html`] }).output();
}

console.log(`Written to ${outDir}: qualified/not-qualified .html, .txt`);
