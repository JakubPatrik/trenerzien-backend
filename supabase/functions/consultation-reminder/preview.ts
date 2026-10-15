// Renders the consultation reminder with sample data and opens it in the browser.
// Nothing is sent. Writes the HTML and plain-text versions.
//
//   deno run -A supabase/functions/consultation-reminder/preview.ts [out-dir]

import { reminderEmail } from "./email.ts";

const outDir = Deno.args[0] ?? await Deno.makeTempDir({ prefix: "consultation-email-" });
await Deno.mkdir(outDir, { recursive: true });

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";

const email = reminderEmail({
  to: "anna@example.sk",
  recipientName: "Anka",
  startsAt: new Date("2026-10-21T17:00:00Z"),
  timeZone: "Europe/Bratislava",
  baseUrl: "https://klub.trenerzien.sk",
});
await Deno.writeTextFile(`${outDir}/reminder.html`, email.html);
await Deno.writeTextFile(`${outDir}/reminder.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
console.log(email.subject);
await new Deno.Command(opener, { args: [`${outDir}/reminder.html`] }).output();

console.log(`Written to ${outDir}: reminder.html/.txt`);
