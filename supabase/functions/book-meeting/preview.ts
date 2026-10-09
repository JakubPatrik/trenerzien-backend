// Renders the booking emails (lead, helper, owner) with sample data and opens them in the browser.
// Nothing is sent. Writes the HTML, plain-text and .ics (lead, helper) versions of each.
//
//   deno run -A supabase/functions/book-meeting/preview.ts [out-dir]
//
// Open the written .ics too (macOS: `open <dir>/lead.ics`) to check how Calendar imports it.

import { type BookingData, helperEmail, leadEmail, ownerEmail } from "./email.ts";

const outDir = Deno.args[0] ?? await Deno.makeTempDir({ prefix: "booking-email-" });
await Deno.mkdir(outDir, { recursive: true });

const start = new Date("2026-10-06T10:00:00+02:00"); // Bratislava time, independent of this machine's TZ

const data: BookingData = {
  eventId: "0123456789abcdef0123456789abcdef",
  organizerEmail: "pohovory@trenerzien.sk",
  start,
  end: new Date(start.getTime() + 60 * 60_000),
  timeZone: "Europe/Bratislava",
  meetLink: "https://meet.google.com/abc-defg-hij",
  lead: {
    name: "Jana Nováková",
    email: "lead@example.com",
    phone: "+421 900 123 456",
    answers: {
      age: 38,
      current_weight: 78.5,
      target_weight: 65,
      health_issues: "Štítna žľaza (Hashimoto), užívam Letrox.",
      occupation: "Účtovníčka, 8 hodín denne v sede.",
      hobbies: "Turistika, čítanie, záhrada.",
      genetics: null,
      life_changes: "Po druhom dieťati som pribrala 12 kg.\nPred rokom som sa presťahovala a zmenila prácu.",
      obstacles: "Nedostatok času a jojo efekt po každej diéte. Večer sa prejedám.",
      vision_one_year: "Chcem mať energiu na deti, cítiť sa dobre vo svojom tele a zabehnúť 10 km.",
      expectations: "Jasný plán, ktorý zvládnem popri rodine, a niekoho, kto ma podrží.",
    },
  },
  helper: { name: "Jakub Patrik", email: "helper@example.com" },
};

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";

const emails = [
  ["lead", leadEmail(data)],
  ["helper", helperEmail(data)],
  ["owner", ownerEmail(data, "pohovory@trenerzien.sk")],
] as const;

for (const [name, email] of emails) {
  await Deno.writeTextFile(`${outDir}/${name}.html`, email.html);
  await Deno.writeTextFile(`${outDir}/${name}.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
  for (const a of email.attachments ?? []) await Deno.writeTextFile(`${outDir}/${name}.ics`, a.content);
  console.log(`${name}: ${email.subject}`);
  await new Deno.Command(opener, { args: [`${outDir}/${name}.html`] }).output();
}

console.log(`Written to ${outDir}: lead/helper/owner .html, .txt; lead/helper .ics`);
