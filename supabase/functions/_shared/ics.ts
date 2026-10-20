// Calendar invite (.ics, RFC 5545 / iMIP) attached to the confirmation email.
// METHOD:REQUEST with an ORGANIZER and the recipient as ATTENDEE is what makes
// Gmail / Outlook / Apple Mail render their native event card with RSVP and
// "add to calendar" — a METHOD:PUBLISH file only shows up as a plain attachment.

export type IcsEvent = {
  uid: string;
  start: Date;
  end: Date;
  summary: string;
  description: string;
  url: string;
  organizer: { email: string; name: string };
  attendee: { email: string; name: string };
};

// 20261006T080000Z
function utc(d: Date): string {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}

// Parameter values (CN=...) must be quoted when they contain ":;,".
function param(s: string): string {
  return `"${s.replace(/"/g, "'")}"`;
}

function text(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// Lines longer than 75 octets are folded (CRLF + space), without splitting a UTF-8 character.
function fold(line: string): string {
  const enc = new TextEncoder();
  const out: string[] = [];
  let current = "";
  let bytes = 0;
  for (const ch of line) {
    const n = enc.encode(ch).length;
    if (bytes + n > (out.length ? 74 : 75)) {
      out.push(current);
      current = "";
      bytes = 0;
    }
    current += ch;
    bytes += n;
  }
  out.push(current);
  return out.join("\r\n ");
}

export function buildIcs(e: IcsEvent): string {
  return [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Trener ZIEN//Booking//SK",
    "CALSCALE:GREGORIAN",
    "METHOD:REQUEST",
    "BEGIN:VEVENT",
    `UID:${e.uid}`,
    "SEQUENCE:0",
    `DTSTAMP:${utc(new Date())}`,
    `DTSTART:${utc(e.start)}`,
    `DTEND:${utc(e.end)}`,
    `SUMMARY:${text(e.summary)}`,
    `DESCRIPTION:${text(e.description)}`,
    `LOCATION:${text(e.url)}`,
    `URL:${e.url}`,
    `ORGANIZER;CN=${param(e.organizer.name)}:mailto:${e.organizer.email}`,
    `ATTENDEE;CN=${param(e.attendee.name)};ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:${e.attendee.email}`,
    "STATUS:CONFIRMED",
    "BEGIN:VALARM",
    "ACTION:DISPLAY",
    `DESCRIPTION:${text(e.summary)}`,
    "TRIGGER:-PT30M",
    "END:VALARM",
    "END:VEVENT",
    "END:VCALENDAR",
  ].map(fold).join("\r\n") + "\r\n";
}
