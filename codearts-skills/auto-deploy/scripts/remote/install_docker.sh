#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0
REGISTRY_MIRRORS="${AUTO_DEPLOY_DOCKER_REGISTRY_MIRRORS:-}"
REGION="${AUTO_DEPLOY_REGION:-}"
IMAGE_REGISTRY_PREFIX="${AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX:-}"

usage() {
  cat <<'EOF'
Usage: install_docker.sh [--registry-mirrors URL[,URL...]] [--image-registry-prefix PREFIX] [--region REGION] [--dry-run]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry-mirrors) REGISTRY_MIRRORS="$2"; shift 2 ;;
    --image-registry-prefix) IMAGE_REGISTRY_PREFIX="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

log() { printf '[auto-deploy][docker] %s\n' "$*" >&2; }

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %q' "$1" >&2
    shift || true
    for arg in "$@"; do printf ' %q' "$arg" >&2; done
    printf '\n' >&2
    return 0
  fi
  "$@"
}

have_docker() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

have_compose() {
  docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}

install_docker_apt() {
  if [[ ! -f /etc/os-release ]]; then
    return 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID_LIKE:-} ${ID:-}" in
    *debian*|*ubuntu*)
      run_cmd sudo apt-get update -y
      run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
      sudo touch /tmp/.auto-deploy-apt-updated
      ;;
    *)
      return 1
      ;;
  esac
}

install_compose_apt() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    return 0
  fi
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
  else
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose
  fi
}

install_docker_fallback() {
  log "apt Docker install failed; falling back to get.docker.com"
  if ! command -v curl >/dev/null 2>&1; then
    run_cmd sudo apt-get update -y
    run_cmd sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] curl -fsSL https://get.docker.com | sudo sh"
    return 0
  fi
  curl -fsSL https://get.docker.com | sudo sh
}

configure_registry_mirrors() {
  [[ -n "$REGISTRY_MIRRORS" ]] || return 0
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required to write valid Docker daemon JSON" >&2; return 3; }
  tmp="$(mktemp)"
  if [[ "$DRY_RUN" == "1" ]]; then
    python3 - "$REGISTRY_MIRRORS" <<'PY'
import json, sys
mirrors=[m.strip() for m in sys.argv[1].split(",") if m.strip()]
print(json.dumps({"registry-mirrors": mirrors}, ensure_ascii=False, indent=2))
PY
    log "[dry-run] would write registry mirrors to /etc/docker/daemon.json"
    return 0
  fi
  sudo mkdir -p /etc/docker
  python3 - "$REGISTRY_MIRRORS" /etc/docker/daemon.json > "$tmp" <<'PY'
import json, sys
mirrors=[m.strip() for m in sys.argv[1].split(",") if m.strip()]
target=sys.argv[2]
data={}
try:
    with open(target, encoding="utf-8") as f:
        data=json.load(f)
except FileNotFoundError:
    data={}
except json.JSONDecodeError as exc:
    raise SystemExit(f"existing daemon.json is invalid JSON: {exc}")
if mirrors:
    data["registry-mirrors"]=mirrors
print(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))
PY
  sudo install -m 0644 "$tmp" /etc/docker/daemon.json
  rm -f "$tmp"
  sudo systemctl restart docker
  docker info >/dev/null
}
auto_configure_cn_mirrors() {
  [[ -n "$REGISTRY_MIRRORS" ]] && return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would auto-configure registry mirrors for Huawei Cloud China region"
    return 0
  fi

  local region_id
  if [[ -n "$REGION" ]]; then region_id="$REGION"; else region_id="$(curl -s --connect-timeout 3 http://169.254.169.254/openstack/latest/meta_data.json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("region_id",""))' 2>/dev/null || true)"; fi

  if [[ "$region_id" != cn-* ]]; then
    log "region_id='''$region_id''' is not a China region, skipping auto mirror config"
    return 0
  fi

  log "Detected Huawei Cloud China region ($region_id), configuring registry mirrors"
  command -v python3 >/dev/null 2>&1 || { log "python3 not available, cannot write daemon.json"; return 3; }
  sudo mkdir -p /etc/docker
  local tmp
  tmp="$(mktemp)"
  python3 - "$tmp" <<'PY'
import json, sys
target = sys.argv[1]
mirrors = ["https://docker.m.daocloud.io", "https://hub-mirror.c.163.com"]
data = {}
try:
    with open(target, encoding="utf-8") as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    pass
data["registry-mirrors"] = mirrors
with open(target, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
PY
  sudo install -m 0644 "$tmp" /etc/docker/daemon.json
  rm -f "$tmp"
  sudo systemctl restart docker
  sleep 3

  if docker info 2>&1 | grep -q "Registry Mirrors"; then
    log "registry mirrors configured and verified successfully"
  else
    log "WARNING: registry mirrors may not have taken effect"
  fi
}


write_registry_prefix() {
  [[ -n "$IMAGE_REGISTRY_PREFIX" ]] || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "[dry-run] would write image registry prefix to /etc/auto-deploy/docker.env"
    return 0
  fi
  sudo mkdir -p /etc/auto-deploy
  printf 'AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX=%q\n' "$IMAGE_REGISTRY_PREFIX" | sudo tee /etc/auto-deploy/docker.env >/dev/null
}

if have_docker && have_compose; then
  log "Docker and Compose already installed"
  docker --version || true
  docker compose version || docker-compose --version || true
  if [[ -n "$REGISTRY_MIRRORS" ]]; then configure_registry_mirrors; else auto_configure_cn_mirrors; fi
  write_registry_prefix
  exit 0
fi

if ! have_docker; then
  if ! install_docker_apt; then
    install_docker_fallback
  fi
fi

install_compose_apt || {
  echo "Docker Compose installation failed. Check apt repositories or install docker-compose-v2/docker-compose-plugin manually." >&2
  exit 5
}

target_user="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo root)}}"
run_cmd sudo usermod -aG docker "$target_user" || true
if [[ -n "$REGISTRY_MIRRORS" ]]; then configure_registry_mirrors; else auto_configure_cn_mirrors; fi
write_registry_prefix

if [[ "$DRY_RUN" != "1" ]]; then
  docker info >/dev/null || { echo "docker info failed after installation" >&2; exit 6; }
  have_compose || { echo "docker compose/docker-compose is unavailable after installation" >&2; exit 7; }
  sudo touch /tmp/.auto-deploy-apt-updated
  docker --version
  docker compose version || docker-compose --version
fi