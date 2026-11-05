#!/usr/bin/env bash
# Runs on the GitHub runner, so it takes the same way as a visitor: DNS, firewall, Caddy, TLS, app.
# Usage: smoke-test.sh https://videoflix.example.com
set -Eeuo pipefail

BASE_URL="${1:?Usage: smoke-test.sh <https base url>}"
HOST="${BASE_URL#https://}"
readonly CERT_MIN_SECONDS=604800

# curl verifies the certificate; the retries give Caddy time to reach the recreated containers
fetch() {
  curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
    --max-time 10 --retry 12 --retry-delay 5 --retry-all-errors "$1"
}

# Body in a variable: grep -q in a pipe would end curl early and fail under pipefail
echo "Health: database and cache answer"
BODY="$(fetch "${BASE_URL}/api/health/")" || { echo "::error::Health endpoint not reachable."; exit 1; }
grep -Eq '"status": *"ok"' <<< "${BODY}" || { echo "::error::Health check failed."; exit 1; }

echo "Start page: the Angular app is served"
BODY="$(fetch "${BASE_URL}/")" || { echo "::error::Start page not reachable."; exit 1; }
grep -q '<app-root' <<< "${BODY}" || { echo "::error::Start page does not contain the app."; exit 1; }

echo "TLS: certificate valid for at least 7 more days"
openssl s_client -connect "${HOST}:443" -servername "${HOST}" < /dev/null 2> /dev/null \
  | openssl x509 -noout -checkend "${CERT_MIN_SECONDS}" > /dev/null \
  || { echo "::error::Certificate expires within 7 days or could not be read."; exit 1; }

echo "Smoke test passed."
