// Renders the three notification emails with sample data and opens them in the browser.
// Nothing is sent. Writes the HTML and plain-text versions of each.
//
//   deno run -A supabase/functions/notify-emails/preview.ts [out-dir]

import { KINDS, notificationEmail } from "./email.ts";

const outDir = Deno.args[0] ?? await Deno.makeTempDir({ prefix: "notify-email-" });
await Deno.mkdir(outDir, { recursive: true });

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";

for (const kind of KINDS) {
  const email = notificationEmail({
    kind,
    to: "anna@example.sk",
    recipientName: "Anka",
    actorName: "Jana Nováková",
    ref: "0d6a7c1e-2b3f-4a5d-9e8f-123456789abc",
    baseUrl: "https://klub.trenerzien.sk",
  });
  await Deno.writeTextFile(`${outDir}/${kind}.html`, email.html);
  await Deno.writeTextFile(`${outDir}/${kind}.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
  console.log(`${kind}: ${email.subject}`);
  await new Deno.Command(opener, { args: [`${outDir}/${kind}.html`] }).output();
}

console.log(`Written to ${outDir}: ${KINDS.map((k) => `${k}.html/.txt`).join(", ")}`);
