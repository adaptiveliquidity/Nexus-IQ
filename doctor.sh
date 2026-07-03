#!/usr/bin/env bash
#
# doctor.sh — live health report for the NexusIQ stack.
#
# One PASS/FAIL line per check, output exactly as:  `PASS <desc>` / `FAIL <desc>`.
# Exits non-zero if ANY check FAILs. Warnings (⚠) are advisory and do not fail
# the run. Everything is checked LIVE against the running stack — no mocks. If a
# check cannot run, it FAILs clearly rather than pretending to pass.
#
set -euo pipefail

# ---- colored helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
ENV_FILE="${ROOT_DIR}/.env"

FAILS=0
WARNS=0
pass() { printf '%s✓%s %sPASS%s %s\n' "$C_GREEN" "$C_RESET" "$C_GREEN" "$C_RESET" "$*"; }
fail() { printf '%s✗%s %sFAIL%s %s\n' "$C_RED"   "$C_RESET" "$C_RED"   "$C_RESET" "$*" >&2; FAILS=$((FAILS+1)); }
warn() { printf '%s⚠%s %sWARN%s %s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET" "$*"; WARNS=$((WARNS+1)); }
head() { printf '\n%s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }

compose() { docker compose "$@"; }

# ---- safe .env loader -------------------------------------------------------
declare -A ENVV
load_env() {
  [[ -f "$ENV_FILE" ]] || return 1
  local raw line key val
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="${key//[[:space:]]/}"
    if   [[ "$val" == \"*\" ]]; then val="${val%\"}"; val="${val#\"}"
    elif [[ "$val" == \'*\' ]]; then val="${val%\'}"; val="${val#\'}"; fi
    [[ -z "$key" ]] && continue
    ENVV["$key"]="$val"
  done < "$ENV_FILE"
}
v() { printf '%s' "${ENVV[$1]:-}"; }
is_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes|on|enabled) return 0 ;; *) return 1 ;;
  esac
}

head "NexusIQ doctor — live health report"

# ---- 0. .env present --------------------------------------------------------
if load_env; then
  pass ".env present and readable"
else
  fail ".env missing at ${ENV_FILE} — run ./install.sh first"
fi

AEON_PORT="$(v AEON_PORT)"; AEON_PORT="${AEON_PORT:-8080}"
AEON_BASE="http://127.0.0.1:${AEON_PORT}"
MGMT_KEY="$(v MANAGEMENT_API_KEY)"
AGENT="$(v NEXUS_AEON_AGENT_ID)"; AGENT="${AGENT:-nexusiq}"

# ---- 1. Docker running + docker compose present -----------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  pass "Docker daemon running"
else
  fail "Docker daemon not running (or 'docker' not on PATH)"
fi
if docker compose version >/dev/null 2>&1; then
  pass "docker compose available"
else
  fail "'docker compose' plugin not available"
fi

# ---- 2. compose services defined --------------------------------------------
DEFINED=""
DEFINED="$(compose config --services 2>/dev/null || true)"
DEFINED_TOOLS=""
DEFINED_TOOLS="$(compose --profile tools config --services 2>/dev/null || true)"
for svc in postgres aeon aeon-worker nexus-agentd nexus-mcp; do
  # nexus-mcp is profile-gated (--profile tools) and won't appear in the
  # default service list. Check the tools-profile listing for it specifically.
  if [[ "$svc" == "nexus-mcp" ]]; then
    if printf '%s\n' "$DEFINED_TOOLS" | grep -qx "$svc"; then
      pass "compose service defined: ${svc} (--profile tools)"
    else
      fail "compose service NOT defined: ${svc} (checked --profile tools)"
    fi
  elif printf '%s\n' "$DEFINED" | grep -qx "$svc"; then
    pass "compose service defined: ${svc}"
  else
    fail "compose service NOT defined: ${svc}"
  fi
done

# ---- 3. postgres healthy ----------------------------------------------------
PG_USER="$(v POSTGRES_USER)"; PG_USER="${PG_USER:-nexusiq}"
PG_DB="$(v POSTGRES_DB)"; PG_DB="${PG_DB:-nexusiq}"
if compose exec -T postgres pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
  pass "Postgres healthy (pg_isready)"
else
  fail "Postgres not accepting connections (pg_isready failed)"
fi

# ---- 4. AEON-IQ /health returns 200 -----------------------------------------
health_code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "${AEON_BASE}/health" 2>/dev/null || true)"
if [[ "$health_code" == "200" ]]; then
  pass "AEON-IQ /health returns 200"
else
  fail "AEON-IQ /health did not return 200 (got '${health_code:-no-response}' at ${AEON_BASE})"
fi

# ---- 4b. AEON-IQ worker healthy ---------------------------------------------
# aeon-worker has no host port, so probe it inside its own container. This
# check matters: with `aeon` pinned to MEMORYOS_ROLE=proxy,
# EXTRACTION_OUTBOX_ENABLED defaults to true, so extraction jobs are only ever
# enqueued, never run inline — only aeon-worker (MEMORYOS_ROLE=worker) drains
# that queue. A dead worker means chat completions keep succeeding while no
# memory is ever persisted, with no other visible symptom.
if compose exec -T aeon-worker curl -sf -m 10 http://localhost:8080/health >/dev/null 2>&1; then
  pass "AEON-IQ worker /health returns 200"
else
  fail "AEON-IQ worker /health check failed — extraction jobs will queue but never drain"
fi

# ---- 5. management API authed (200 WITH key, 401/403 WITHOUT) ---------------
if [[ -z "$MGMT_KEY" ]]; then
  fail "AEON-IQ management API: MANAGEMENT_API_KEY missing — cannot test auth"
else
  authed_code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    -H "X-Management-Key: ${MGMT_KEY}" "${AEON_BASE}/api/v1/stats" 2>/dev/null || true)"
  if [[ "$authed_code" == "200" ]]; then
    pass "AEON-IQ management API authenticated (GET /api/v1/stats → 200)"
  else
    fail "AEON-IQ management API authed call failed (GET /api/v1/stats → '${authed_code:-no-response}')"
  fi

  unauth_code="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "${AEON_BASE}/api/v1/stats" 2>/dev/null || true)"
  if [[ "$unauth_code" == "401" || "$unauth_code" == "403" ]]; then
    pass "AEON-IQ management API rejects unauthenticated requests (no key → ${unauth_code})"
  else
    fail "AEON-IQ management API unauthenticated (no-key request returned '${unauth_code:-no-response}', expected 401/403 — auth NOT enforced)"
  fi
fi

# ---- 6. nexus-agentd live ---------------------------------------------------
if compose exec -T nexus-agentd nexus daemon ping --socket /run/nexus/nexus-agentd.sock >/dev/null 2>&1; then
  pass "nexus-agentd live (daemon ping)"
elif compose exec -T nexus-agentd test -S /run/nexus/nexus-agentd.sock >/dev/null 2>&1; then
  pass "nexus-agentd live (socket present at /run/nexus/nexus-agentd.sock)"
else
  fail "nexus-agentd not live (no daemon ping, socket file absent)"
fi

# ---- 7. nexus-mcp live (initialize + tools/list) ----------------------------
if bash "${ROOT_DIR}/scripts/smoke-nexus-execute.sh" >/dev/null 2>&1; then
  pass "nexus-mcp live (initialize + tools/list listed tools)"
else
  fail "nexus-mcp handshake failed (no tools listed over connect-mcp.sh)"
fi

# ---- 8. data dirs writable --------------------------------------------------
for d in data/proofs data/timeline; do
  abs="${ROOT_DIR}/${d}"
  mkdir -p "$abs" 2>/dev/null || true
  if [[ -d "$abs" ]] && touch "${abs}/.doctor-write-test" 2>/dev/null; then
    rm -f "${abs}/.doctor-write-test" 2>/dev/null || true
    pass "${d} writable"
  else
    fail "${d} NOT writable (${abs})"
  fi
done

# ---- 9. no mock/test/synthetic env active -----------------------------------
mock_hit=0
for key in "${!ENVV[@]}"; do
  case "$key" in
    MOCK_*|*SYNTHETIC*|TEST_MODE|BENCH_MODE)
      if is_truthy "${ENVV[$key]}"; then
        fail "mock/test variable active: ${key} is truthy — refusing to validate against a faked stack"
        mock_hit=1
      fi
      ;;
  esac
done
if is_truthy "$(v ALLOW_UNAUTH_MANAGEMENT)"; then
  fail "ALLOW_UNAUTH_MANAGEMENT is truthy — management plane auth is disabled (forbidden)"
  mock_hit=1
fi
if [[ "$mock_hit" -eq 0 ]]; then
  pass "no mock/test/synthetic flags active; management auth not disabled"
fi

# ---- 10. provider key present (warn, not fail) ------------------------------
provider="$(printf '%s' "$(v UPSTREAM_PROVIDER)" | tr '[:upper:]' '[:lower:]')"
provider="${provider:-openai}"
provider_key=""
case "$provider" in
  openai)    provider_key="$(v OPENAI_API_KEY)" ;;
  anthropic) provider_key="$(v ANTHROPIC_API_KEY)" ;;
  gemini)    provider_key="$(v GEMINI_API_KEY)" ;;
  ollama)    provider_key="$(v UPSTREAM_BASE_URL)" ;;  # ollama uses a base URL, not a key
  *)         provider_key="" ;;
esac
if [[ -n "$provider_key" ]]; then
  pass "provider key present for UPSTREAM_PROVIDER=${provider}"
else
  warn "no provider key for UPSTREAM_PROVIDER=${provider} — memory write/recall (embeddings) will be UNAVAILABLE; Nexus execution + proofs still work"
fi

# ---- 11. evidence counter-signature verification (warn, not fail) -----------
verifying_key="$(v NEXUS_AEON_VERIFYING_KEY)"
if [[ -z "$verifying_key" ]]; then
  warn "NEXUS_AEON_VERIFYING_KEY not set — Nexus does not verify AEON-IQ's evidence counter-signatures (capsules stay Advisory). Pin it from: curl -s -H \"X-Management-Key: \$MANAGEMENT_API_KEY\" http://127.0.0.1:${AEON_PORT:-8080}/api/v1/evidence/verifying-key"
else
  reported="$(curl -sf -H "X-Management-Key: $(v MANAGEMENT_API_KEY)" "http://127.0.0.1:${AEON_PORT:-8080}/api/v1/evidence/verifying-key" 2>/dev/null || true)"
  reported_key="$(printf '%s' "$reported" | sed -n 's/.*"key_id":"\([0-9a-f]*\)".*/\1/p')"
  reported_persistent="$(printf '%s' "$reported" | grep -o '"persistent":[a-z]*' | cut -d: -f2)"
  if [[ -z "$reported_key" ]]; then
    warn "could not read AEON-IQ's evidence verifying key to cross-check NEXUS_AEON_VERIFYING_KEY"
  elif [[ "$reported_key" != "$verifying_key" ]]; then
    fail "NEXUS_AEON_VERIFYING_KEY does not match AEON-IQ's reported evidence key — verification will fail closed (hits dropped, Degraded attestation)"
  elif [[ "$reported_persistent" != "true" ]]; then
    fail "AEON-IQ is using an EPHEMERAL evidence signing key (AEON_EVIDENCE_SIGNING_KEY unset) — the pinned NEXUS_AEON_VERIFYING_KEY will break on next restart"
  else
    pass "evidence counter-signature key pinned and matches AEON-IQ (persistent)"
  fi
fi

# ---- verdict ----------------------------------------------------------------
head "Summary"
if [[ "$FAILS" -eq 0 ]]; then
  printf '%s✓ doctor: all checks passed%s' "$C_GREEN" "$C_RESET"
  [[ "$WARNS" -gt 0 ]] && printf ' %s(%d warning(s))%s' "$C_YELLOW" "$WARNS" "$C_RESET"
  printf '\n'
  exit 0
else
  printf '%s✗ doctor: %d check(s) FAILED%s' "$C_RED" "$FAILS" "$C_RESET"
  [[ "$WARNS" -gt 0 ]] && printf ' %s(+%d warning(s))%s' "$C_YELLOW" "$WARNS" "$C_RESET"
  printf '\n'
  exit 1
fi
