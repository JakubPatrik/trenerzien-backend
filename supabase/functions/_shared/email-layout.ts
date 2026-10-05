// Shared HTML layout for our SmartEmailing emails (booking, invitations, applications):
// black header with the wordmark, eyebrow + headline with an italic accent word,
// optional detail table, optional stacked answers (question above, free text below),
// red button, note with a red left border, black footer.

export const RED = "#B8292F";
export const INK = "#0B0B0D";
const MUTED = "#6B6B6B";
const LINE = "#E2E2E2";

// Web fonts where the client supports them (Apple Mail, iOS), safe fallbacks elsewhere (Gmail).
const FONT_DISPLAY = "'Bebas Neue','Oswald','Arial Narrow',Impact,sans-serif";
const FONT_SERIF = "'Playfair Display',Georgia,'Times New Roman',serif";
const FONT_MONO = "'JetBrains Mono','Courier New',monospace";
const FONT_SANS = "Inter,Arial,Helvetica,sans-serif";

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

export const firstName = (name: string) => name.trim().split(/\s+/)[0] || name;

export const link = (href: string, label: string) =>
  `<a href="${escapeHtml(href)}" style="color:${INK};font-weight:600;">${escapeHtml(label)}</a>`;

export type Layout = {
  title: string;
  eyebrow: string;
  headline: string; // plain words, then the italic accent word
  accent: string;
  intro: string; // HTML
  rows?: [label: string, value: string][]; // HTML values
  answers?: [question: string, answer: string][]; // HTML answers; long free text, stacked
  button: { label: string; href: string };
  note: string; // HTML
  year: number;
};

export function layout(l: Layout): string {
  const rows = l.rows ?? [];
  const row = ([label, value]: [string, string], i: number) => {
    const border = i < rows.length - 1 ? `border-bottom:1px solid ${LINE};` : "";
    return `
          <tr>
            <td style="padding:18px 20px;${border}font-family:${FONT_SANS};font-size:16px;color:${MUTED};">${label}</td>
            <td align="right" style="padding:18px 20px;${border}font-family:${FONT_SANS};font-size:16px;font-weight:600;color:${INK};">${value}</td>
          </tr>`;
  };
  const table = rows.length
    ? `
    <tr><td style="padding:28px 32px 0;">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border:1px solid ${LINE};border-collapse:separate;">
        ${rows.map(row).join("")}
      </table>
    </td></tr>`
    : "";
  const answers = l.answers ?? [];
  const answer = ([question, text]: [string, string], i: number) => `
        <div style="padding:${i ? "18px" : "0"} 0 18px;${i ? `border-top:1px solid ${LINE};` : ""}">
          <div style="font-family:${FONT_MONO};font-size:11px;letter-spacing:2px;text-transform:uppercase;color:${MUTED};">${question}</div>
          <div style="margin-top:8px;font-family:${FONT_SANS};font-size:16px;line-height:1.5;color:${INK};">${text}</div>
        </div>`;
  const answerBlock = answers.length
    ? `
    <tr><td style="padding:28px 32px 0;">${answers.map(answer).join("")}
    </td></tr>`
    : "";

  return `<!doctype html>
<html lang="sk"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link href="https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Inter:wght@400;600&family=JetBrains+Mono&family=Playfair+Display:ital@1&display=swap" rel="stylesheet">
<title>${l.title}</title>
</head>
<body style="margin:0;padding:0;background:#F2F2F2;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#F2F2F2;"><tr><td align="center" style="padding:24px 12px;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#FFFFFF;border-radius:8px;overflow:hidden;">
    <tr><td align="center" style="background:${INK};padding:18px 32px;font-family:${FONT_SANS};font-size:22px;font-weight:600;letter-spacing:-0.3px;color:#FFFFFF;">
      tréner <span style="color:${RED};">ŽIEN</span>
    </td></tr>
    <tr><td style="padding:36px 32px 0;">
      <div style="font-family:${FONT_MONO};font-size:12px;letter-spacing:4px;text-transform:uppercase;color:${RED};">${l.eyebrow}</div>
      <h1 style="margin:14px 0 0;font-family:${FONT_DISPLAY};font-size:44px;line-height:1;font-weight:normal;text-transform:uppercase;color:${INK};">${l.headline} <span style="font-family:${FONT_SERIF};font-style:italic;text-transform:none;color:${RED};">${l.accent}</span></h1>
      <p style="margin:16px 0 0;font-family:${FONT_SANS};font-size:16px;line-height:1.5;color:#444;">${l.intro}</p>
    </td></tr>${table}${answerBlock}
    <tr><td style="padding:24px 32px 0;">
      <a href="${escapeHtml(l.button.href)}" style="display:block;background:${RED};color:#FFFFFF;text-align:center;padding:17px;font-family:${FONT_SANS};font-size:17px;font-weight:600;text-decoration:none;">${l.button.label}</a>
    </td></tr>
    <tr><td style="padding:24px 32px 36px;">
      <div style="border-left:3px solid ${RED};padding:2px 0 2px 16px;font-family:${FONT_SANS};font-size:15px;line-height:1.55;color:#444;">
        ${l.note}
      </div>
    </td></tr>
    <tr><td align="center" style="background:${INK};padding:20px 32px;font-family:${FONT_SANS};font-size:14px;color:#9A9A9A;">
      © ${l.year} Tréner ŽIEN · Mgr. Daniel Čmel.
    </td></tr>
  </table>
</td></tr></table>
</body></html>`;
}
