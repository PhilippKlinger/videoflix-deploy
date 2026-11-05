#!/usr/bin/env bash
# Runs on the server, piped over SSH by the deploy workflow:
#   ssh target bash -s -- deploy backend sha256:<digest> < scripts/deploy.sh
# Commands: deploy <backend|frontend> <sha256:digest> | rollback | finish
#
# The running digests live in compose.override.yaml (gitignored). Compose merges it automatically,
# so manual commands such as "docker compose ps" on the server see the same images.
set -Eeuo pipefail

cd "${DEPLOY_PATH:-/srv/videoflix}"

readonly BACKEND_REPO=ghcr.io/philippklinger/videoflix-backend
readonly FRONTEND_REPO=ghcr.io/philippklinger/videoflix-frontend
readonly STATE_FILE=.deploy-previous
readonly OVERRIDE_FILE=compose.override.yaml

running_image() {
  local id
  id="$(docker compose ps -q "$1")"
  [[ -n "${id}" ]] || { echo "Service $1 is not running." >&2; return 1; }
  docker inspect -f '{{.Config.Image}}' "${id}"
}

# From compose.yaml alone: after a rollback the override must not bring back a service of a newer commit
backend_services() {
  docker compose -f compose.yaml config --services | grep -vxE 'db|redis|frontend'
}

write_override() {
  local service
  {
    echo '# Written by the deploy workflow, do not edit by hand.'
    echo 'services:'
    for service in $(backend_services); do
      printf '  %s:
    image: %s
' "${service}" "$1"
    done
    printf '  frontend:
    image: %s
' "$2"
  } > "${OVERRIDE_FILE}.tmp"
  mv -f "${OVERRIDE_FILE}.tmp" "${OVERRIDE_FILE}"
}

start_stack() {
  docker compose pull --quiet
  # --wait fails as soon as a service does not become healthy in time
  docker compose up -d --no-build --wait --wait-timeout 240 --remove-orphans
}

verify_running() {
  local service
  for service in $(backend_services); do
    [[ "$(running_image "${service}")" == "$1" ]] || { echo "${service} does not run the approved image." >&2; return 1; }
  done
  [[ "$(running_image frontend)" == "$2" ]] || { echo "frontend does not run the approved image." >&2; return 1; }
}

deploy() {
  local service="$1" digest="$2" backend frontend
  [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Invalid digest." >&2; return 1; }

  [[ -f .env ]] || { echo ".env is missing on the server." >&2; return 1; }
  (( (8#$(stat -c '%a' .env) & 077) == 0 )) || { echo ".env grants group/other permissions." >&2; return 1; }

  backend="$(running_image web)"
  frontend="$(running_image frontend)"

  # From here on a failure is rolled back by the workflow
  {
    printf 'PREVIOUS_BACKEND=%s\n' "${backend}"
    printf 'PREVIOUS_FRONTEND=%s\n' "${frontend}"
    printf 'PREVIOUS_COMMIT=%s\n' "$(git rev-parse HEAD)"
  } > "${STATE_FILE}"

  case "${service}" in
    backend) backend="${BACKEND_REPO}@${digest}" ;;
    frontend) frontend="${FRONTEND_REPO}@${digest}" ;;
    *) echo "Unknown service." >&2; return 1 ;;
  esac

  git pull --quiet --ff-only origin main
  write_override "${backend}" "${frontend}"
  start_stack
  verify_running "${backend}" "${frontend}"
}

rollback() {
  [[ -f "${STATE_FILE}" ]] || { echo "Nothing to roll back."; return 0; }
  # shellcheck disable=SC1090
  source "./${STATE_FILE}"
  git reset --quiet --keep "${PREVIOUS_COMMIT}"
  write_override "${PREVIOUS_BACKEND}" "${PREVIOUS_FRONTEND}"
  start_stack
  verify_running "${PREVIOUS_BACKEND}" "${PREVIOUS_FRONTEND}"
  rm -f "${STATE_FILE}"
}

finish() {
  rm -f "${STATE_FILE}"
  # Keep the images of the last week: a rollback then does not depend on the registry
  docker image prune -f --filter 'until=168h' > /dev/null || true
}

case "${1:-}" in
  deploy) deploy "${2:-}" "${3:-}" ;;
  rollback) rollback ;;
  finish) finish ;;
  *) echo "Usage: deploy.sh deploy <backend|frontend> <sha256:digest> | rollback | finish" >&2; exit 2 ;;
esac
