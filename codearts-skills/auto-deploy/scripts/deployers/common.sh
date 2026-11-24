#!/usr/bin/env bash
set -euo pipefail

DEPLOYER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$DEPLOYER_DIR/.." && pwd)"

REPO="" HOST="" USER="" KEY="" ANALYSIS="" APP_NAME="" REMOTE_DIR="" EVENTS=""
PORT="" START_COMMAND="" BUILD_COMMAND="" NODE_VERSION="${AUTO_DEPLOY_NODE_VERSION:-18}"
REGION="${AUTO_DEPLOY_REGION:-}"
DOCKER_REGISTRY_MIRRORS="${AUTO_DEPLOY_DOCKER_REGISTRY_MIRRORS:-}"
IMAGE_REGISTRY_PREFIX="${AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX:-}"
DOCKER_BUILD_TIMEOUT="${AUTO_DEPLOY_DOCKER_BUILD_TIMEOUT:-2400}"
APP_ENV_FILE=""
ALLOW_NATIVE_FULLSTACK=0
REMOTE_ENV_FILE=""

parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|--project) REPO="$2"; shift 2 ;;
      --host) HOST="$2"; shift 2 ;;
      --user) USER="$2"; shift 2 ;;
      --key) KEY="$2"; shift 2 ;;
      --analysis) ANALYSIS="$2"; shift 2 ;;
      --app-name) APP_NAME="$2"; shift 2 ;;
      --remote-dir) REMOTE_DIR="$2"; shift 2 ;;
      --events) EVENTS="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --start-command) START_COMMAND="$2"; shift 2 ;;
      --build-command) BUILD_COMMAND="$2"; shift 2 ;;
      --node-version) NODE_VERSION="$2"; shift 2 ;;
      --docker-registry-mirrors) DOCKER_REGISTRY_MIRRORS="$2"; shift 2 ;;
      --image-registry-prefix) IMAGE_REGISTRY_PREFIX="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      --docker-build-timeout) DOCKER_BUILD_TIMEOUT="$2"; shift 2 ;;
      --env-file) APP_ENV_FILE="$2"; shift 2 ;;
      --allow-native-fullstack) ALLOW_NATIVE_FULLSTACK=1; shift ;;
      *) echo "unknown deployer argument: $1" >&2; exit 2 ;;
    esac
  done
  [[ -d "$REPO" && -f "$ANALYSIS" && -n "$HOST" && -n "$USER" && -f "$KEY" && -n "$APP_NAME" && -n "$REMOTE_DIR" ]] || {
    echo "deployer missing required arguments" >&2
    exit 2
  }
  chmod 600 "$KEY" || true
  KNOWN_HOSTS="${KEY}.known_hosts"
  SSH=(ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER@$HOST")
  SCP=(scp -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new)
  REMOTE_ENV_FILE="/etc/auto-deploy/${APP_NAME}.env"
}

json_get() {
  python3 - "$ANALYSIS" "$1" <<'PY'
import json, sys
data=json.load(open(sys.argv[1], encoding="utf-8-sig"))
value=data
for part in sys.argv[2].split("."):
    if isinstance(value, dict):
        value=value.get(part, "")
    else:
        value=""
print("" if value is None else value)
PY
}

duration_since() {
  python3 - "$1" <<'PY'
import sys, time
print(f"{time.time() - float(sys.argv[1]):.3f}")
PY
}

emit_event() {
  local step="$1" status="$2" duration="$3" message="${4:-}"
  if [[ -n "$EVENTS" ]]; then
    mkdir -p "$(dirname "$EVENTS")"
    python3 - "$EVENTS" "$step" "$status" "$duration" "$message" <<'PY'
import json, sys, time
path, step, status, duration, message = sys.argv[1:6]
event = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "step": step,
    "status": status,
    "duration_seconds": float(duration or 0),
    "message": message,
}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
PY
  fi
  printf '[auto-deploy][%s][%s] %s\n' "$step" "$status" "$message" >&2
}

run_step() {
  local step="$1"; shift
  local start output status duration errexit_enabled=0
  start="$(python3 - <<'PY'
import time
print(time.time())
PY
)"
  [[ "$-" == *e* ]] && errexit_enabled=1
  set +e
  output="$("$@" 2>&1)"
  status=$?
  if [[ "$errexit_enabled" == "1" ]]; then set -e; else set +e; fi
  duration="$(duration_since "$start")"
  if [[ "$status" == "0" ]]; then
    emit_event "$step" "success" "$duration" "${output##*$'\n'}"
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    return 0
  fi
  emit_event "$step" "failed" "$duration" "${output##*$'\n'}"
  [[ -n "$output" ]] && printf '%s\n' "$output" >&2
  return "$status"
}

remote_exec() {
  "${SSH[@]}" "$@"
}

remote_bash() {
  "${SSH[@]}" "bash -lc $(printf '%q' "$1")"
}

remote_script() {
  local workdir="${1:-}"
  local local_tmp remote_tmp remote_cmd status
  local_tmp="$(mktemp)"
  cat >"$local_tmp"
  remote_tmp="/tmp/auto-deploy-${APP_NAME:-app}-${RANDOM}-${RANDOM}.sh"
  copy_to_remote "$local_tmp" "$remote_tmp"
  rm -f "$local_tmp"
  remote_cmd="set -euo pipefail; chmod +x '$remote_tmp';"
  if [[ -n "$workdir" ]]; then
    remote_cmd+=" cd $(printf '%q' "$workdir");"
  fi
  remote_cmd+=" '$remote_tmp'"
  set +e
  "${SSH[@]}" "$remote_cmd"
  status=$?
  set -e
  "${SSH[@]}" "rm -f '$remote_tmp'" >/dev/null 2>&1 || true
  return "$status"
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex, sys
print(shlex.quote(sys.argv[1]))
PY
}

docker_build_timeout() {
  case "${DOCKER_BUILD_TIMEOUT:-}" in
    ''|*[!0-9]*) printf '2400' ;;
    *) printf '%s' "$DOCKER_BUILD_TIMEOUT" ;;
  esac
}

remote_install_file() {
  local remote_path="$1"
  local mode="${2:-644}"
  local owner="${3:-root}"
  local group="${4:-root}"
  local local_tmp remote_tmp status
  local_tmp="$(mktemp)"
  cat >"$local_tmp"
  remote_tmp="/tmp/auto-deploy-file-${APP_NAME:-app}-${RANDOM}-${RANDOM}"
  copy_to_remote "$local_tmp" "$remote_tmp"
  rm -f "$local_tmp"
  set +e
  "${SSH[@]}" "sudo install -m $(printf '%q' "$mode") -o $(printf '%q' "$owner") -g $(printf '%q' "$group") '$remote_tmp' $(printf '%q' "$remote_path") && rm -f '$remote_tmp'"
  status=$?
  set -e
  "${SSH[@]}" "rm -f '$remote_tmp'" >/dev/null 2>&1 || true
  return "$status"
}

install_remote_env_file() {
  if [[ -n "$APP_ENV_FILE" && -f "$APP_ENV_FILE" ]]; then
    remote_bash "sudo mkdir -p /etc/auto-deploy"
    remote_install_file "$REMOTE_ENV_FILE" 600 root root <"$APP_ENV_FILE"
  else
    remote_bash "sudo mkdir -p /etc/auto-deploy; sudo install -m 600 -o root -g root /dev/null $(printf '%q' "$REMOTE_ENV_FILE")"
  fi
}

merge_remote_env_into_compose_env() {
  install_remote_env_file
  remote_script "$REMOTE_DIR/current" <<SCRIPT
touch .env
while IFS= read -r line || [ -n "\$line" ]; do
  case "\$line" in
    ''|'#'*) continue ;;
  esac
  key="\${line%%=*}"
  case "\$key" in
    ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
  esac
  if grep -qE "^\\s*\${key}=" .env; then
    echo "[auto-deploy] env key conflict in compose .env; keeping existing value for \${key}"
  else
    printf '%s\n' "\$line" >> .env
    echo "[auto-deploy] env key added to compose .env: \${key}"
  fi
done < "$REMOTE_ENV_FILE"
SCRIPT
}

copy_to_remote() {
  "${SCP[@]}" "$1" "$USER@$HOST:$2"
}

has_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  command -v "${cmd}.cmd" >/dev/null 2>&1 && return 0
  command -v "${cmd}.exe" >/dev/null 2>&1 && return 0
  where "$cmd" >/dev/null 2>&1 && return 0
  return 1
}

install_docker_remote() {
  local remote_script="/tmp/auto-deploy-install-docker.sh"
  copy_to_remote "$SCRIPT_DIR/remote/install_docker.sh" "$remote_script"
  local cmd="chmod +x '$remote_script' && '$remote_script'"
  if [[ -n "$DOCKER_REGISTRY_MIRRORS" ]]; then
    cmd+=" --registry-mirrors $(printf '%q' "$DOCKER_REGISTRY_MIRRORS")"
  fi
  if [[ -n "$IMAGE_REGISTRY_PREFIX" ]]; then
    cmd+=" --image-registry-prefix $(printf '%q' "$IMAGE_REGISTRY_PREFIX")"
  fi
  if [[ -n "$REGION" ]]; then
    cmd+=" --region $(printf '%q' "$REGION")"
  fi
  local mirror_status=0
  remote_bash "$cmd" || mirror_status=$?
  if [[ "$mirror_status" == "0" ]]; then
    emit_event configure_registry_mirror success 0 "docker registry mirror configuration completed"
  else
    emit_event configure_registry_mirror failed 0 "docker registry mirror configuration failed"
    return $mirror_status
  fi
}

remote_apt_install() {
  local packages="$*"
  if ! remote_bash "test -f /tmp/.auto-deploy-apt-updated" 2>/dev/null; then
    remote_bash "sudo apt-get update -y && sudo apt-get install -y $packages && sudo touch /tmp/.auto-deploy-apt-updated"
  else
    remote_bash "sudo apt-get install -y $packages"
  fi
}

optimize_dockerfiles_for_cache() {
  local remote_optimizer="/tmp/auto-deploy-optimize-dockerfiles-${APP_NAME:-app}.py"
  copy_to_remote "$SCRIPT_DIR/optimize_dockerfiles.py" "$remote_optimizer"
  remote_bash "python3 '$remote_optimizer' '$REMOTE_DIR/current' || true; rm -f '$remote_optimizer'"
}

remote_common_prefix() {
  printf "set -euo pipefail; cd %q;" "$REMOTE_DIR/current"
}
