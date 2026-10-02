#!/usr/bin/env bash
# One-time: get a Google OAuth refresh token for the master calendar account
# (the account whose calendar holds the booking events and Meet links).
#
#   GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=… ./11-google-refresh-token.sh
#
# Prereqs (Google Cloud Console, project of your choice):
#   1. APIs & Services → Library → enable "Google Calendar API".
#   2. OAuth consent screen: Workspace → "Internal"; Gmail → "External" and
#      PUBLISH to "In production" — in "Testing" Google expires refresh tokens
#      after 7 days. (Unverified-app warning on the consent screen is fine,
#      only the master account signs in.)
#   3. Credentials → Create OAuth client ID → type "Desktop app".
# Sign in as the master account in the browser window that opens. Then store
# the printed token with 12-set-booking-secrets.sh (GOOGLE_REFRESH_TOKEN).
set -euo pipefail

: "${GOOGLE_CLIENT_ID:?set GOOGLE_CLIENT_ID}"
: "${GOOGLE_CLIENT_SECRET:?set GOOGLE_CLIENT_SECRET}"

python3 - <<'PY'
import http.server, json, os, secrets, sys, urllib.parse, urllib.request, webbrowser

CLIENT_ID = os.environ["GOOGLE_CLIENT_ID"]
CLIENT_SECRET = os.environ["GOOGLE_CLIENT_SECRET"]
SCOPE = "https://www.googleapis.com/auth/calendar.events"
PORT = 8765
REDIRECT = f"http://127.0.0.1:{PORT}/"
state = secrets.token_urlsafe(16)

auth_url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode({
    "client_id": CLIENT_ID, "redirect_uri": REDIRECT, "response_type": "code", "scope": SCOPE,
    "access_type": "offline", "prompt": "consent", "state": state,
})
result = {}

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if "code" not in q and "error" not in q:
            self.send_response(404); self.end_headers(); return
        result.update({k: v[0] for k, v in q.items()})
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.end_headers()
        self.wfile.write("<h2>Hotovo — môžeš zavrieť okno a vrátiť sa do terminálu.</h2>".encode())
    def log_message(self, *a): pass

server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
print("Opening the browser. If it doesn't open, visit:\n\n" + auth_url + "\n", file=sys.stderr)
webbrowser.open(auth_url)
while not result:
    server.handle_request()

if result.get("error"):
    sys.exit(f"Authorization failed: {result['error']}")
if result.get("state") != state:
    sys.exit("State mismatch — aborting.")

req = urllib.request.Request("https://oauth2.googleapis.com/token", data=urllib.parse.urlencode({
    "code": result["code"], "client_id": CLIENT_ID, "client_secret": CLIENT_SECRET,
    "redirect_uri": REDIRECT, "grant_type": "authorization_code",
}).encode())
try:
    tokens = json.load(urllib.request.urlopen(req))
except urllib.error.HTTPError as e:
    sys.exit(f"Token exchange failed ({e.code}): {e.read().decode()}")

if "refresh_token" not in tokens:
    sys.exit("No refresh_token returned — remove the app's access at myaccount.google.com/permissions and retry.")
if SCOPE not in tokens.get("scope", ""):
    sys.exit(f"Calendar scope not granted (got: {tokens.get('scope')}) — tick the calendar checkbox on the consent screen.")

print("\nGOOGLE_REFRESH_TOKEN:\n")
print(tokens["refresh_token"])
print("\nStore it: GOOGLE_REFRESH_TOKEN=… ./12-set-booking-secrets.sh", file=sys.stderr)
PY
