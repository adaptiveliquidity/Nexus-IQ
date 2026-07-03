#!/usr/bin/env bash
#
# install.sh — one-shot installer for the NexusIQ self-host kit.
#
# Prepares the kit so `./start.sh` can bring the stack up:
#   * verifies docker + `docker compose`
#   * creates .env from .env.example (if missing)
#   * generates blank secrets and cross-wires NEXUS_AEON_MANAGEMENT_KEY
#   * validates the resulting .env
#   * vendors the Nexus and AEON-IQ build contexts into ./vendor
#   * copies the Nexus Dockerfile into the vendored context
#   * records the installing host uid/gid in .env
#   * creates ./data/{proofs,timeline,modules,logs,run}
#   * bakes a sample WASM module if missing
#   * builds images and pulls base images
#
# Flags:
#   --start         start the stack after a successful install
#   --build-local   force a local image build (this is ALSO the default
#                   behaviour when images are not pullable)
#
# Secrets are NEVER echoed. Steps are trapped individually so a failure points
# at the exact step that broke.
#
set -euo pipefail

# ---- colored helpers --------------------------------------------------------
if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=''; C_RED=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi
ok()    { printf '%s✓%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
err()   { printf '%s✗%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
warn()  { printf '%s⚠%s %s\n'  "$C_YELLOW" "$C_RESET" "$*"; }
step()  { printf '\n%s%s▸ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ---- per-step trap ----------------------------------------------------------
CURRENT_STEP="startup"
on_err() {
  local rc=$?
  err "install failed during: ${CURRENT_STEP} (exit ${rc})"
  exit "$rc"
}
trap on_err ERR

run_step() { CURRENT_STEP="$1"; step "$1"; }

# ---- flag parsing -----------------------------------------------------------
DO_START=0
FORCE_LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --start)       DO_START=1 ;;
    --build-local) FORCE_LOCAL=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--start] [--build-local]
  --start         start the stack after install
  --build-local   force local image build (default when images aren't pullable)
EOF
      exit 0
      ;;
    *) err "unknown flag: ${arg}"; exit 2 ;;
  esac
done

compose() { docker compose "$@"; }

# Args: $1 = key, $2 = value. Updates an existing .env entry or appends it.
set_env_value() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp "${ROOT_DIR}/.env.XXXXXX")"
  if grep -qE "^${key}=" "${ROOT_DIR}/.env"; then
    KEY="$key" VALUE="$value" awk '
      BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
      {
        if ($0 ~ "^" k "=") { print k "=" v; done = 1 }
        else { print }
      }
      END { if (!done) print k "=" v }
    ' "${ROOT_DIR}/.env" > "$tmp"
  else
    cp "${ROOT_DIR}/.env" "$tmp"
    KEY="$key" VALUE="$value" awk 'BEGIN { print ENVIRON["KEY"] "=" ENVIRON["VALUE"] }' >> "$tmp"
  fi
  chmod --reference="${ROOT_DIR}/.env" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv "$tmp" "${ROOT_DIR}/.env"
}

# ============================================================================
run_step "Checking prerequisites (docker, docker compose)"
# ============================================================================
if ! command -v docker >/dev/null 2>&1; then
  err "docker is not installed or not on PATH. Install Docker Engine: https://docs.docker.com/engine/install/"
  exit 1
fi
ok "docker found: $(docker --version 2>/dev/null || echo '?')"

if ! docker compose version >/dev/null 2>&1; then
  err "'docker compose' (v2) is not available. Install the Compose plugin: https://docs.docker.com/compose/install/"
  exit 1
fi
ok "docker compose found: $(docker compose version --short 2>/dev/null || echo '?')"

if ! docker info >/dev/null 2>&1; then
  err "Docker daemon is not reachable. Start Docker and re-run."
  exit 1
fi
ok "docker daemon is reachable"

# ============================================================================
run_step "Preparing .env"
# ============================================================================
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  if [[ ! -f "${ROOT_DIR}/.env.example" ]]; then
    err "Neither .env nor .env.example exists in ${ROOT_DIR}. Cannot continue."
    exit 1
  fi
  cp "${ROOT_DIR}/.env.example" "${ROOT_DIR}/.env"
  chmod 600 "${ROOT_DIR}/.env"
  ok "created .env from .env.example"
else
  ok ".env already exists — keeping it"
fi

set_env_value NEXUSIQ_UID "$(id -u)"
set_env_value NEXUSIQ_GID "$(id -g)"
ok "recorded host identity in .env (NEXUSIQ_UID/NEXUSIQ_GID)"

# ============================================================================
run_step "Generating secrets"
# ============================================================================
bash "${ROOT_DIR}/scripts/generate-secrets.sh"

# ============================================================================
run_step "Validating .env"
# ============================================================================
bash "${ROOT_DIR}/scripts/validate-env.sh"

# ============================================================================
# Prebuilt-image fast path: skip source vendoring and local compilation
# entirely and pull the cosign-signed release images from ghcr instead.
# Requires a published release (see RELEASING.md / VERSION_MATRIX.md for the
# tag ↔ image mapping). Becomes the recommended default once v1.0 images
# exist; until then, source build remains the default.
# ============================================================================
if [[ "${NEXUSIQ_USE_PREBUILT:-false}" == "true" ]]; then
  run_step "Prebuilt-image mode (NEXUSIQ_USE_PREBUILT=true)"
  PREBUILT_TAG="${NEXUSIQ_IMAGE_TAG:-latest}"
  if [[ -z "${NEXUSIQ_IMAGE_TAG:-}" ]]; then
    # Unlike the source-build path (SHA-pinned via NEXUSIQ_NEXUS_REF /
    # NEXUSIQ_AEON_REF), `latest` floats: it is whatever each repo's
    # tag-triggered publish.yml most recently pushed, independent of this
    # kit's own VERSION_MATRIX row. Two operators running this same install.sh
    # on different days can silently get different Nexus/AEON-IQ builds. Once
    # a real kit release is tagged, set NEXUSIQ_IMAGE_TAG to that release's
    # tag (see VERSION_MATRIX.md) for a reproducible pull.
    warn "NEXUSIQ_IMAGE_TAG not set — pulling the floating ':latest' tag, which is NOT pinned to this kit's VERSION_MATRIX row and is not reproducible across installs. Set NEXUSIQ_IMAGE_TAG=<release tag> once one exists."
  fi
  # Only set the image refs if the operator hasn't overridden them.
  grep -q '^NEXUS_IMAGE=' "${ROOT_DIR}/.env" 2>/dev/null     || echo "NEXUS_IMAGE=ghcr.io/adaptiveliquidity/nexusiq-nexus:${PREBUILT_TAG}" >> "${ROOT_DIR}/.env"
  grep -q '^AEON_IQ_IMAGE=' "${ROOT_DIR}/.env" 2>/dev/null     || echo "AEON_IQ_IMAGE=ghcr.io/adaptiveliquidity/aeon-iq:${PREBUILT_TAG}" >> "${ROOT_DIR}/.env"
  ok "image refs set in .env (tag: ${PREBUILT_TAG})"
  if compose pull aeon aeon-worker nexus-agentd; then
    ok "prebuilt images pulled"
  else
    err "could not pull prebuilt images from ghcr (no release published yet, or no network)."
    err "Re-run without NEXUSIQ_USE_PREBUILT to build from source instead."
    exit 1
  fi
  # Data directories + the sample module are still needed in prebuilt mode.
  for d in proofs timeline modules logs run; do
    mkdir -p "${ROOT_DIR}/data/${d}"
  done
  SAMPLE_WASM="${ROOT_DIR}/data/modules/sample_tool.wasm"
  if [[ ! -f "$SAMPLE_WASM" ]]; then
    WASM_B64='AGFzbQEAAAABBAFgAAADAgEABQMBAAEHEQIGbWVtb3J5AgAGX3N0YXJ0AAAKBAECAAsACgRuYW1lAgMBAAA='
    printf '%s' "$WASM_B64" | base64 -d > "$SAMPLE_WASM"
    ok "baked data/modules/sample_tool.wasm"
  fi
  ok "prebuilt-image install complete — run ./start.sh next"
  exit 0
fi

# ============================================================================
run_step "Vendoring build contexts into ./vendor"
# ============================================================================
mkdir -p "${ROOT_DIR}/vendor"

# Link an existing checkout into vendor/<name>, replacing any prior symlink.
# Args: $1 = absolute source path, $2 = vendor target name.
link_checkout() {
  local src="$1" name="$2" dest="${ROOT_DIR}/vendor/$2"
  if [[ -L "$dest" || -e "$dest" ]]; then
    # If it's already the right symlink, leave it.
    if [[ -L "$dest" && "$(readlink -f "$dest" 2>/dev/null)" == "$(readlink -f "$src" 2>/dev/null)" ]]; then
      ok "vendor/${name} already linked to ${src}"
      return 0
    fi
    # Refuse to clobber a real (non-symlink) directory that has content.
    if [[ -d "$dest" && ! -L "$dest" ]]; then
      warn "vendor/${name} is a real directory — leaving it in place"
      return 0
    fi
    rm -f "$dest"
  fi
  ln -s "$src" "$dest"
  ok "symlinked vendor/${name} -> ${src}"
}

# ---- Nexus ----
if [[ -n "${NEXUSIQ_VENDOR_NEXUS:-}" && -d "${NEXUSIQ_VENDOR_NEXUS}" ]]; then
  link_checkout "$(readlink -f "${NEXUSIQ_VENDOR_NEXUS}")" "nexus"
elif [[ -e "${ROOT_DIR}/vendor/nexus" ]]; then
  ok "vendor/nexus already present"
else
  warn "NEXUSIQ_VENDOR_NEXUS not set — cloning Nexus from GitHub"
  # Pinned to a known-good Nexus commit for reproducible installs (bump deliberately).
  # Includes #156: clean-install healthcheck (nexus daemon ping) + proof-capsule fuel + RUSTSEC-2026-0185.
  NEXUS_PIN="${NEXUSIQ_NEXUS_REF:-85780b8a1d306d08e8ef333a950bdbe0c3d8e76c}"
  if git clone --filter=blob:none https://github.com/adaptiveliquidity/Nexus.git "${ROOT_DIR}/vendor/nexus" \
       && git -C "${ROOT_DIR}/vendor/nexus" checkout --quiet "${NEXUS_PIN}"; then
    ok "cloned Nexus into vendor/nexus (pinned ${NEXUS_PIN})"
  else
    err "Failed to clone/checkout pinned Nexus (${NEXUS_PIN}). Set NEXUSIQ_VENDOR_NEXUS=/path/to/Nexus and re-run."
    exit 1
  fi
fi

# ---- AEON-IQ ----
if [[ -n "${NEXUSIQ_VENDOR_AEON:-}" && -d "${NEXUSIQ_VENDOR_AEON}" ]]; then
  link_checkout "$(readlink -f "${NEXUSIQ_VENDOR_AEON}")" "aeon-iq"
elif [[ -e "${ROOT_DIR}/vendor/aeon-iq" ]]; then
  ok "vendor/aeon-iq already present"
else
  warn "NEXUSIQ_VENDOR_AEON not set — cloning AEON-IQ from GitHub"
  # Pinned to a known-good AEON-IQ commit for reproducible installs (bump
  # deliberately, together with the VERSION_MATRIX row). Includes the
  # two-stage ANN retrieval fix, RMK reward loop, sensitivity enforcement,
  # and Ed25519 evidence counter-signing.
  AEON_PIN="${NEXUSIQ_AEON_REF:-76f09b4}"
  if git clone --filter=blob:none https://github.com/adaptiveliquidity/AEON-IQ.git "${ROOT_DIR}/vendor/aeon-iq" 2>/dev/null        && git -C "${ROOT_DIR}/vendor/aeon-iq" checkout --quiet "${AEON_PIN}"; then
    ok "cloned AEON-IQ into vendor/aeon-iq (pinned ${AEON_PIN})"
  else
    err "Could not clone AEON-IQ (the repository may be private or the URL unknown)."
    err "Set NEXUSIQ_VENDOR_AEON to your local AEON-IQ checkout and re-run, e.g.:"
    err "    NEXUSIQ_VENDOR_AEON=/home/ahpsi/AEON-IQ ./install.sh"
    exit 1
  fi
fi

# ============================================================================
run_step "Installing Dockerfile into vendored Nexus context"
# ============================================================================
SRC_DOCKERFILE="${ROOT_DIR}/docker/Dockerfile.nexus"
DST_DOCKERFILE="${ROOT_DIR}/vendor/nexus/Dockerfile.nexusiq"
if [[ ! -f "$SRC_DOCKERFILE" ]]; then
  err "Expected ${SRC_DOCKERFILE} to exist (it ships with the kit). Cannot continue."
  exit 1
fi
# Resolve the real path even through the vendor/nexus symlink so we write into
# the actual checkout.
NEXUS_REAL="$(readlink -f "${ROOT_DIR}/vendor/nexus")"
cp "$SRC_DOCKERFILE" "${NEXUS_REAL}/Dockerfile.nexusiq"
ok "copied docker/Dockerfile.nexus -> vendor/nexus/Dockerfile.nexusiq"

# ============================================================================
run_step "Creating data directories"
# ============================================================================
for d in proofs timeline modules logs run; do
  mkdir -p "${ROOT_DIR}/data/${d}"
done
ok "ensured ./data/{proofs,timeline,modules,logs,run}"

# ============================================================================
run_step "Baking sample WASM module"
# ============================================================================
SAMPLE_WASM="${ROOT_DIR}/data/modules/sample_tool.wasm"
if [[ -f "$SAMPLE_WASM" ]]; then
  ok "sample_tool.wasm already present — skipping"
else
  # Minimal noop module:
  #   (module (memory (export "memory") 1) (func (export "_start")))
  WASM_B64='AGFzbQEAAAABBAFgAAADAgEABQMBAAEHEQIGbWVtb3J5AgAGX3N0YXJ0AAAKBAECAAsACgRuYW1lAgMBAAA='
  if printf '%s' "$WASM_B64" | base64 -d > "$SAMPLE_WASM" 2>/dev/null; then
    ok "baked data/modules/sample_tool.wasm"
  else
    err "Failed to decode sample WASM (base64 -d unavailable?)."
    exit 1
  fi
fi

# ============================================================================
run_step "Building images"
# ============================================================================
# Default policy: build locally. --build-local makes it explicit but local
# build is also the fallback whenever the images aren't pullable.
if [[ "$FORCE_LOCAL" -eq 1 ]]; then
  ok "local build forced (--build-local)"
fi
if compose build; then
  ok "docker compose build complete"
else
  err "docker compose build failed."
  exit 1
fi

# ============================================================================
run_step "Pulling base images"
# ============================================================================
# Pull any images referenced via `image:` (e.g. postgres). Build-only services
# are ignored; failure here is non-fatal because the local build already
# produced the app images.
if compose pull --ignore-buildable 2>/dev/null || compose pull 2>/dev/null; then
  ok "base images pulled"
else
  warn "could not pull some base images (will rely on locally built / cached images)"
fi

# ============================================================================
# Done — next steps
# ============================================================================
printf '\n%s%s✓ NexusIQ install complete.%s\n' "$C_BOLD" "$C_GREEN" "$C_RESET"

if [[ "$DO_START" -eq 1 ]]; then
  run_step "Starting stack (--start)"
  CURRENT_STEP="start.sh"
  exec bash "${ROOT_DIR}/start.sh"
fi

printf '\n%sNext steps:%s\n' "$C_BOLD" "$C_RESET"
printf '  %s./start.sh%s                 start the stack (postgres, aeon, nexus-agentd)\n' "$C_DIM" "$C_RESET"
printf '  %s./logs.sh%s                  follow logs\n' "$C_DIM" "$C_RESET"
printf '  %s./generate-mcp-config.sh%s   emit MCP client config for nexus-mcp\n' "$C_DIM" "$C_RESET"
printf '  %s./stop.sh%s                  stop the stack (volumes preserved)\n' "$C_DIM" "$C_RESET"
echo
