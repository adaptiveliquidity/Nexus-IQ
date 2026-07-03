#!/usr/bin/env bash
#
# wait-for-health.sh — poll docker compose health until the core services are
# healthy, or time out (~120s). Prints per-service status as it goes.
#
# Core services: postgres, aeon, aeon-worker, nexus-agentd.
#
# aeon-worker matters here, not just cosmetically: with `aeon` pinned to
# MEMORYOS_ROLE=proxy, EXTRACTION_OUTBOX_ENABLED defaults to true, so the
# proxy *always* enqueues extraction jobs instead of running them inline —
# only a MEMORYOS_ROLE=worker process drains that queue. If aeon-worker is
# down, chat completions keep succeeding but no memory is ever persisted,
# silently. Waiting on its healthcheck here means a broken worker fails
# start.sh loudly instead of failing invisibly later.
set -euo pipefail

# ---- colored helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_RESET=''
fi
ok()   { printf '%s✓%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
err()  { printf '%s✗%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
warn() { printf '%s⚠%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
cd "$ROOT_DIR"

SERVICES=(postgres aeon aeon-worker nexus-agentd)
TIMEOUT="${WAIT_TIMEOUT:-120}"   # seconds
INTERVAL=3                       # seconds between polls

# ---- compose wrapper --------------------------------------------------------
compose() { docker compose "$@"; }

# ---- inspect health of one service ------------------------------------------
# Echoes one of: healthy | unhealthy | starting | no-healthcheck | running |
# exited | missing. Uses `docker inspect` on the service container so we get
# the real Health.Status; falls back to State when there is no healthcheck.
service_state() {
  local svc="$1" cid health state
  cid="$(compose ps -q "$svc" 2>/dev/null | head -n1 || true)"
  if [[ -z "$cid" ]]; then
    printf 'missing'
    return
  fi
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || printf 'unknown')"
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || printf 'unknown')"
  if [[ "$state" == "exited" || "$state" == "dead" ]]; then
    printf 'exited'
    return
  fi
  case "$health" in
    healthy)   printf 'healthy' ;;
    unhealthy) printf 'unhealthy' ;;
    starting)  printf 'starting' ;;
    none)
      # No healthcheck declared: treat a running container as ready.
      if [[ "$state" == "running" ]]; then printf 'no-healthcheck'; else printf '%s' "$state"; fi
      ;;
    *)         printf '%s' "${state:-unknown}" ;;
  esac
}

# Is the given state considered "ready"?
is_ready() {
  case "$1" in
    healthy|no-healthcheck) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Waiting for services to become healthy (timeout ${TIMEOUT}s): ${SERVICES[*]}"

deadline=$(( $(date +%s) + TIMEOUT ))
declare -A LAST
for s in "${SERVICES[@]}"; do LAST["$s"]=""; done

while true; do
  all_ready=1
  for svc in "${SERVICES[@]}"; do
    st="$(service_state "$svc")"
    if [[ "${LAST[$svc]}" != "$st" ]]; then
      case "$st" in
        healthy|no-healthcheck) ok   "${svc}: ${st}" ;;
        unhealthy|exited|missing) err "${svc}: ${st}" ;;
        *) warn "${svc}: ${st}" ;;
      esac
      LAST["$svc"]="$st"
    fi
    is_ready "$st" || all_ready=0
  done

  if [[ "$all_ready" -eq 1 ]]; then
    echo
    ok "All core services are healthy."
    exit 0
  fi

  if [[ "$(date +%s)" -ge "$deadline" ]]; then
    echo
    err "Timed out after ${TIMEOUT}s waiting for: ${SERVICES[*]}"
    echo "Current status:"
    compose ps || true
    echo
    echo "Inspect logs with:  ./logs.sh <service>"
    exit 1
  fi

  sleep "$INTERVAL"
done
