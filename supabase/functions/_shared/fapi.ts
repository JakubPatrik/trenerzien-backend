// Shared FAPI helpers: notification security check + a minimal GET client.
// Docs: https://web.fapi.cz/api-doc/ ("Url notifications", "Invoices").

import { createHash } from "node:crypto";

const FAPI_API = "https://api.fapi.cz";

// deno-lint-ignore no-explicit-any
export type FapiObject = Record<string, any>;

export class FapiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function hex(algorithm: "md5" | "sha1", s: string): string {
  return createHash(algorithm).update(s, "utf8").digest("hex");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Same as Fapi\FapiClient\Tools\SecurityChecker::isInvoiceSecurityValid():
//   sha1(time . invoice.id . invoice.number . md5(item1.id . item1.name) . md5(item2.id . item2.name) ...)
// `time` is the integer from the notification (PHP casts it with (int)).
export function isInvoiceSecurityValid(invoice: FapiObject, time: number, security: string): boolean {
  // deno-lint-ignore no-explicit-any
  const itemsHash = (invoice.items ?? []).map((i: any) => hex("md5", `${i.id}${i.name}`)).join("");
  const expected = hex("sha1", `${time}${invoice.id}${invoice.number}${itemsHash}`);
  return timingSafeEqual(security.toLowerCase(), expected);
}

// GET https://api.fapi.cz/<path> with Basic auth (FAPI login + password = API key);
// throws FapiError with FAPI's message on non-2xx.
export async function fapiGet(path: string, username: string, password: string): Promise<FapiObject> {
  const res = await fetch(`${FAPI_API}/${path}`, {
    headers: {
      Authorization: `Basic ${btoa(`${username}:${password}`)}`,
      Accept: "application/json",
    },
  });
  const body = await res.json().catch(() => null);
  if (!res.ok) {
    throw new FapiError(`FAPI GET ${path} failed (${res.status}): ${body?.message ?? "unknown"}`, res.status);
  }
  return body;
}
