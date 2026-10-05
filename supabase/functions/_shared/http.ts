// JSON responses + CORS for browser-facing functions.
//
// BOOKING_ALLOWED_ORIGINS: comma-separated origins allowed to call from a
// browser (e.g. "https://trenerzien.sk,https://www.trenerzien.sk"). Unset →
// any origin ("*"), handy for local testing only.
// Functions that authorize by the caller's JWT (send-invitations) pass
// `anyOrigin` and allow "*" regardless.

export type Cors = { anyOrigin?: boolean };

function allowedOrigin(req: Request, cors: Cors): string | null {
  if (cors.anyOrigin) return "*";
  const list = (Deno.env.get("BOOKING_ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (list.length === 0) return "*";
  const origin = req.headers.get("origin");
  return origin && list.includes(origin) ? origin : null;
}

export function corsHeaders(req: Request, cors: Cors = {}): Record<string, string> {
  const origin = allowedOrigin(req, cors);
  if (!origin) return {};
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

export function json(req: Request, status: number, body: Record<string, unknown>, cors: Cors = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req, cors), "Content-Type": "application/json" },
  });
}

export function preflight(req: Request, cors: Cors = {}): Response {
  return new Response(null, { status: 204, headers: corsHeaders(req, cors) });
}
