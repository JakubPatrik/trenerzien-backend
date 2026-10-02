// SmartEmailing transactional email (API v3, POST /send/transactional-emails-bulk).
//
// Secrets (same names as the other apps):
//   SMARTEMAILING_USERNAME, SMARTEMAILING_API_KEY      Basic auth
//   SMARTEMAILING_SENDER_EMAIL                          confirmed sender in SmartEmailing
//   SMARTEMAILING_SENDER_NAME (optional), SMARTEMAILING_REPLY_TO (optional, confirmed)

const SEND_URL = "https://app.smartemailing.cz/api/v3/send/transactional-emails-bulk";

export class NotConfiguredError extends Error {}

export type Email = {
  to: string;
  subject: string;
  html: string;
  text: string;
  tag: string;
};

// Returns the SmartEmailing message id.
export async function sendEmail(email: Email): Promise<string | null> {
  const username = Deno.env.get("SMARTEMAILING_USERNAME");
  const apiKey = Deno.env.get("SMARTEMAILING_API_KEY");
  const from = Deno.env.get("SMARTEMAILING_SENDER_EMAIL");
  if (!username || !apiKey || !from) {
    throw new NotConfiguredError("SmartEmailing credentials not configured");
  }

  const res = await fetch(SEND_URL, {
    method: "POST",
    headers: {
      Authorization: `Basic ${btoa(`${username}:${apiKey}`)}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      sender_credentials: {
        from,
        reply_to: Deno.env.get("SMARTEMAILING_REPLY_TO") || from,
        sender_name: Deno.env.get("SMARTEMAILING_SENDER_NAME") || "Tréner ŽIEN",
      },
      tag: email.tag,
      message_contents: { subject: email.subject, html_body: email.html, text_body: email.text },
      tasks: [{ recipient: { emailaddress: email.to } }],
    }),
  });

  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.status === "error") {
    throw new Error(`SmartEmailing send failed (${res.status}): ${body.message ?? JSON.stringify(body).slice(0, 300)}`);
  }
  return body.data?.[0]?.id ?? null;
}
