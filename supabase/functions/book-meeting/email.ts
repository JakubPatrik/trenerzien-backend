// Confirmation email (Slovak), styled like the booking page.

import type { Email } from "../_shared/smartemailing.ts";

const RED = "#B8292F";
const SUPPORT_EMAIL = "podpora@trenerzien.sk";

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

// "utorok 6. októbra, 9:00–10:00"
export function formatSlot(start: Date, end: Date, timeZone: string): string {
  const day = new Intl.DateTimeFormat("sk-SK", { timeZone, weekday: "long", day: "numeric", month: "long" })
    .format(start);
  const time = new Intl.DateTimeFormat("sk-SK", { timeZone, hour: "numeric", minute: "2-digit" });
  return `${day}, ${time.format(start)}–${time.format(end)}`;
}

export type ConfirmationData = {
  to: string;
  leadName: string;
  helperName: string;
  start: Date;
  end: Date;
  timeZone: string;
  meetLink: string;
};

export function confirmationEmail(d: ConfirmationData): Email {
  const firstName = d.leadName.trim().split(/\s+/)[0] || d.leadName;
  const when = formatSlot(d.start, d.end, d.timeZone);
  const minutes = Math.round((d.end.getTime() - d.start.getTime()) / 60000);
  const e = escapeHtml;

  const row = (label: string, value: string) => `
    <tr><td style="padding:16px 20px;border:1px solid #E5E5E5;">
      <div style="font-family:Arial,Helvetica,sans-serif;font-size:13px;font-weight:bold;letter-spacing:1px;text-transform:uppercase;color:#0B0B0D;">${label}</div>
      <div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;color:#444;padding-top:4px;">${value}</div>
    </td></tr>
    <tr><td style="height:12px;line-height:12px;font-size:0;">&nbsp;</td></tr>`;

  const html = `<!doctype html>
<html lang="sk"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#F2F2F2;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2F2F2;"><tr><td align="center" style="padding:24px 12px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;">
    <tr><td style="background:#0B0B0D;padding:20px 28px;font-family:Arial,Helvetica,sans-serif;font-size:22px;font-weight:bold;letter-spacing:1px;color:#FFFFFF;">
      TRÉNER <span style="color:${RED};">ŽIEN</span>
    </td></tr>
    <tr><td style="padding:32px 28px 8px;">
      <div style="font-family:'Courier New',monospace;font-size:12px;letter-spacing:4px;color:${RED};text-transform:uppercase;">Rezervácia pohovoru · ${minutes} min</div>
      <h1 style="margin:16px 0 8px;font-family:Arial,Helvetica,sans-serif;font-size:30px;line-height:1.1;color:#0B0B0D;text-transform:uppercase;">Termín je <span style="font-family:Georgia,serif;font-style:italic;text-transform:none;color:${RED};">potvrdený.</span></h1>
      <p style="margin:0 0 24px;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.5;color:#444;">Ahoj ${e(firstName)}, tešíme sa na náš rozhovor.</p>
    </td></tr>
    <tr><td style="padding:0 28px;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
        ${row("Dátum a čas", e(when))}
        ${row("S kým sa porozprávaš", e(d.helperName))}
      </table>
    </td></tr>
    <tr><td style="padding:12px 28px 8px;">
      <a href="${e(d.meetLink)}" style="display:block;background:${RED};color:#FFFFFF;text-align:center;padding:16px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:bold;text-decoration:none;">Pripojiť sa cez Google Meet &rarr;</a>
      <p style="margin:8px 0 0;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#777;text-align:center;">${e(d.meetLink)}</p>
    </td></tr>
    <tr><td style="padding:20px 28px 32px;">
      <div style="border-left:3px solid ${RED};padding:4px 0 4px 16px;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#444;">
        Rezervácia termínu je záväzná a účasť na pohovore je vyžadovaná. Ak sa nemôžeš dostaviť, napíš nám na
        <a href="mailto:${SUPPORT_EMAIL}" style="color:#0B0B0D;font-weight:bold;">${SUPPORT_EMAIL}</a> aspoň 1 deň vopred.
      </div>
      <p style="margin:16px 0 0;font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#777;">Pozvánku s odkazom nájdeš aj v Google kalendári.</p>
    </td></tr>
    <tr><td style="background:#0B0B0D;padding:16px 28px;font-family:Arial,Helvetica,sans-serif;font-size:12px;color:#9A9A9A;">
      © ${d.start.getFullYear()} Tréner ŽIEN · <a href="https://trenerzien.sk" style="color:#9A9A9A;">trenerzien.sk</a>
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;

  const text = [
    `Ahoj ${firstName},`,
    "",
    "tvoj pohovor je potvrdený.",
    "",
    `Dátum a čas: ${when}`,
    `S kým sa porozprávaš: ${d.helperName}`,
    `Google Meet: ${d.meetLink}`,
    "",
    "Rezervácia termínu je záväzná a účasť na pohovore je vyžadovaná.",
    `Ak sa nemôžeš dostaviť, napíš nám na ${SUPPORT_EMAIL} aspoň 1 deň vopred.`,
    "",
    "Tréner ŽIEN — trenerzien.sk",
  ].join("\n");

  return {
    to: d.to,
    subject: `Pohovor potvrdený: ${when}`,
    html,
    text,
    tag: "booking-confirmation",
  };
}
