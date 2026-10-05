// Renders the invitation email with sample data and opens it in the browser.
// Nothing is sent. Writes the HTML and plain-text versions.
//
//   deno run -A supabase/functions/send-invitations/preview.ts [out-dir]

import { inviteEmail } from "./email.ts";

const outDir = Deno.args[0] ?? await Deno.makeTempDir({ prefix: "invite-email-" });
await Deno.mkdir(outDir, { recursive: true });

const email = inviteEmail({
  to: "anna@example.sk",
  fullName: "Anna Nováková",
  inviteUrl: "https://klub.trenerzien.sk/nove-heslo?t=pkce_0123456789abcdef",
});

await Deno.writeTextFile(`${outDir}/invite.html`, email.html);
await Deno.writeTextFile(`${outDir}/invite.txt`, `To: ${email.to}\nSubject: ${email.subject}\n\n${email.text}\n`);
console.log(`Subject: ${email.subject}`);
console.log(`Written to ${outDir}: invite.html, invite.txt`);

const opener = Deno.build.os === "darwin" ? "open" : Deno.build.os === "windows" ? "explorer" : "xdg-open";
await new Deno.Command(opener, { args: [`${outDir}/invite.html`] }).output();
