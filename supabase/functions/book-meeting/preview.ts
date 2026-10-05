// Renders the booking emails (lead + helper) with sample data and opens them in the browser.
// Nothing is sent. Writes the HTML, plain-text and .ics versions of each.
//
//   deno run -A supabase/functions/book-meeting/preview.ts [out-dir]
//
// Open the written .ics too (macOS: `open <dir>/lead.ics`) to check how Calendar imports it.

import { type BookingData, helperEmail, leadEmail } from "./email.ts";

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
  lead: { name: "Jana Nováková", email: "lead@example.com", phone: "+421 900 123 456" },
  helper: { name: "Jakub Patrik", email: "helper@example.com" },
};

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";

for (const [name, email] of [["lead", leadEmail(data)], ["helper", helperEmail(data)]] as const) {
  await Deno.writeTextFile(`${outDir}/${name}.html`, email.html);
  await Deno.writeTextFile(`${outDir}/${name}.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
  for (const a of email.attachments ?? []) await Deno.writeTextFile(`${outDir}/${name}.ics`, a.content);
  console.log(`${name}: ${email.subject}`);
  await new Deno.Command(opener, { args: [`${outDir}/${name}.html`] }).output();
}

console.log(`Written to ${outDir}: lead/helper .html, .txt, .ics`);
