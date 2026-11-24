#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYER_DIR="$SCRIPT_DIR/deployers"

usage() {
  cat <<'EOF'
Usage: deploy.sh --repo PATH --analysis JSON (--resources resource-info.json | --host HOST --user USER --key KEY) [--app-name NAME]
                 [--events deploy-events.jsonl] [--result deploy-result.json]
                 [--docker-registry-mirrors URL[,URL...]] [--image-registry-prefix PREFIX] [--region REGION]
                 [--node-version 18] [--docker-build-timeout SECONDS] [--skip-prepare] [--skip-upload]
                 [--env-file PATH] [--allow-native-fullstack]
EOF
}

REPO="" HOST="" USER="" KEY="" ANALYSIS="" APP_NAME="" RESOURCES="" EVENTS="" RESULT="" INSTANCE_IMAGE_NAME=""
REGION="${AUTO_DEPLOY_REGION:-}"
DOCKER_REGISTRY_MIRRORS="${AUTO_DEPLOY_DOCKER_REGISTRY_MIRRORS:-}"
IMAGE_REGISTRY_PREFIX="${AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX:-}"
NODE_VERSION="${AUTO_DEPLOY_NODE_VERSION:-18}"
DOCKER_BUILD_TIMEOUT="${AUTO_DEPLOY_DOCKER_BUILD_TIMEOUT:-}"
APP_ENV_FILE=""
SKIP_PREPARE=0
SKIP_UPLOAD=0
ALLOW_NATIVE_FULLSTACK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo|--project) REPO="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --analysis) ANALYSIS="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --resources) RESOURCES="$2"; shift 2 ;;
    --events) EVENTS="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --docker-registry-mirrors) DOCKER_REGISTRY_MIRRORS="$2"; shift 2 ;;
    --image-registry-prefix) IMAGE_REGISTRY_PREFIX="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --docker-build-timeout) DOCKER_BUILD_TIMEOUT="$2"; shift 2 ;;
    --env-file) APP_ENV_FILE="$2"; shift 2 ;;
    --skip-prepare) SKIP_PREPARE=1; shift ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --allow-native-fullstack) ALLOW_NATIVE_FULLSTACK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "$RESOURCES" ]]; then
  [[ -f "$RESOURCES" ]] || { echo "resource info file not found: $RESOURCES" >&2; exit 2; }
  eval "$(python3 - "$RESOURCES" <<'PY'
import json, shlex, sys
data=json.load(open(sys.argv[1], encoding="utf-8-sig"))
mapping={"HOST": data.get("public_ip"), "USER": data.get("ssh_user"), "KEY": data.get("ssh_key_path"), "INSTANCE_IMAGE_NAME": data.get("instance_image_name") or data.get("image")}
for key, value in mapping.items():
    print(f"{key}={shlex.quote(str(value or ''))}")
PY
)"
fi

if [[ -z "$REGION" && -n "$RESOURCES" && -f "$RESOURCES" ]]; then
  REGION="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1],encoding='utf-8-sig')); print(d.get('region',''))" "$RESOURCES" 2>/dev/null || true)"
fi

[[ -d "$REPO" && -f "$ANALYSIS" && -n "$HOST" && -n "$USER" && -f "$KEY" ]] || { usage >&2; exit 2; }
chmod 600 "$KEY" || true

read_json() {
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
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "step": step,
        "status": status,
        "duration_seconds": float(duration or 0),
        "message": message,
    }, ensure_ascii=False) + "\n")
PY
  fi
  printf '[auto-deploy][%s][%s] %s\n' "$step" "$status" "$message" >&2
}

run_step() {
  local step="$1"; shift
  local start status duration output errexit_enabled=0
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

run_remote_script() {
  local local_tmp remote_tmp status
  local_tmp="$(mktemp)"
  cat >"$local_tmp"
  remote_tmp="/tmp/auto-deploy-${APP_NAME:-app}-${RANDOM}-${RANDOM}.sh"
  scp -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new "$local_tmp" "$USER@$HOST:$remote_tmp" >/dev/null
  rm -f "$local_tmp"
  set +e
  "${SSH[@]}" "chmod +x '$remote_tmp' && '$remote_tmp'"
  status=$?
  set -e
  "${SSH[@]}" "rm -f '$remote_tmp'" >/dev/null 2>&1 || true
  return "$status"
}

write_result() {
  local status="$1" strategy="$2" fallback_from="${3:-}" message="${4:-}"
  [[ -n "$RESULT" ]] || return 0
  mkdir -p "$(dirname "$RESULT")"
  python3 - "$RESULT" "$status" "$strategy" "$fallback_from" "$message" <<'PY'
import json, sys
path, status, strategy, fallback_from, message = sys.argv[1:6]
data = {"status": status, "strategy": strategy, "fallback_from": fallback_from or None, "message": message}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

APP_NAME="${APP_NAME:-$(basename "$REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')}"
STRATEGY="$(read_json deploy_strategy)"
PORT="$(read_json listen_port)"
START_COMMAND="$(read_json start_command)"
BUILD_COMMAND="$(read_json build_command)"
HAS_SPLIT="$(read_json has_frontend_backend_split)"
HAS_COMPOSE="$(read_json has_docker_compose)"
BACKEND_TYPE="$(read_json modules.backend.project_type)"
K8S_DETECTED="$(read_json kubernetes.detected)"
REMOTE_DIR="/opt/auto-deploy/${APP_NAME}"
KNOWN_HOSTS="${KEY}.known_hosts"
SSH=(ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER@$HOST")

if [[ "$INSTANCE_IMAGE_NAME" =~ JDK|jdk ]]; then
  export SKIP_JDK_INSTALL=1
fi

if [[ "$K8S_DETECTED" == "True" || "$K8S_DETECTED" == "true" ]]; then
  echo "kubernetes manifests detected; this simplified deployer only supports single ECS web application deployment" >&2
  exit 64
fi

if [[ "$STRATEGY" == "native" && "$ALLOW_NATIVE_FULLSTACK" != "1" ]]; then
  if [[ "$HAS_SPLIT" =~ ^([Tt]rue|true|1)$ && ! "$HAS_COMPOSE" =~ ^([Tt]rue|true|1)$ ]]; then
    echo "当前 skill 只稳定支持单体 native 或 Docker Compose。前后端分离项目请提供 docker-compose.yml，或显式使用 --allow-native-fullstack。" >&2
    exit 65
  fi
fi

driver_for() {
  case "$1" in
    docker-compose) echo "$DEPLOYER_DIR/docker_compose.sh" ;;
    docker) echo "$DEPLOYER_DIR/dockerfile.sh" ;;
    native) echo "$DEPLOYER_DIR/native.sh" ;;
    *) echo "unknown deployment strategy: $1" >&2; return 2 ;;
  esac
}

call_driver() {
  local strategy="$1" driver
  local extra_args=()
  driver="$(driver_for "$strategy")"
  [[ -n "$APP_ENV_FILE" ]] && extra_args+=(--env-file "$APP_ENV_FILE")
  [[ "$ALLOW_NATIVE_FULLSTACK" == "1" ]] && extra_args+=(--allow-native-fullstack)
  bash "$driver" \
    --repo "$REPO" \
    --analysis "$ANALYSIS" \
    --host "$HOST" \
    --user "$USER" \
    --key "$KEY" \
    --app-name "$APP_NAME" \
    --remote-dir "$REMOTE_DIR" \
    --events "$EVENTS" \
    --port "$PORT" \
    --start-command "$START_COMMAND" \
    --build-command "$BUILD_COMMAND" \
    --node-version "$NODE_VERSION" \
    --docker-registry-mirrors "$DOCKER_REGISTRY_MIRRORS" \
    --image-registry-prefix "$IMAGE_REGISTRY_PREFIX" \
    --region "$REGION" \
    --docker-build-timeout "$DOCKER_BUILD_TIMEOUT" \
    "${extra_args[@]}"
}

wait_for_ssh() {
  local ok=0
  for i in $(seq 1 30); do
    if "${SSH[@]}" "echo ok >/dev/null" 2>/dev/null; then
      ok=1
      break
    fi
    printf '[auto-deploy] waiting for ssh to become ready (%s/30)\n' "$i" >&2
    sleep 10
  done
  [[ "$ok" == "1" ]] || { echo "ssh did not become ready after 300 seconds: $USER@$HOST" >&2; return 4; }
}

prepare_remote_dir() {
  "${SSH[@]}" "set -e; sudo mkdir -p /opt/auto-deploy; if [ -d '$REMOTE_DIR/current' ]; then sudo rm -rf '$REMOTE_DIR/backup.previous'; sudo mv '$REMOTE_DIR/current' '$REMOTE_DIR/backup.previous'; fi; sudo mkdir -p '$REMOTE_DIR/current'; sudo chown -R '$USER':'$USER' '$REMOTE_DIR'"
}

ensure_remote_dns() {
  # Detect and fix common remote ECS issues before deployment begins.
  local fix_needed=0

  # a. DNS check: Huawei Cloud ECS often has broken systemd-resolved stub.
  if "${SSH[@]}" "nslookup repo.huaweicloud.com >/dev/null 2>&1" 2>/dev/null; then
    printf '[auto-deploy] remote DNS is working
' >&2
  else
    printf '[auto-deploy] remote DNS not working; adding Huawei Cloud internal DNS and 8.8.8.8
' >&2
    run_remote_script <<'SCRIPT' || true
set -euo pipefail
printf '%s\n' 'nameserver 100.125.1.250' 'nameserver 8.8.8.8' | sudo tee -a /etc/resolv.conf >/dev/null
SCRIPT
    fix_needed=1
  fi

  if [[ "$fix_needed" == "1" ]]; then
    printf '[auto-deploy] remote environment fixes applied
' >&2
  fi
}

upload_source() {
  local default_excludes=(
    ".git"
    ".auto-deploy"
    "node_modules"
    ".venv"
    "venv"
    "target"
    "build"
    "dist"
    ".env"
  )
  local ignore_files=()
  [[ -f "$REPO/.auto-deployignore" ]] && ignore_files+=("$REPO/.auto-deployignore")
  [[ -f "$REPO/.gitignore" ]] && ignore_files+=("$REPO/.gitignore")

  if command -v rsync >/dev/null 2>&1; then
    local rsync_args=(-az --delete -e "ssh -i $KEY -o UserKnownHostsFile=$KNOWN_HOSTS -o StrictHostKeyChecking=accept-new")
    local pattern ignore_file
    for pattern in "${default_excludes[@]}"; do
      rsync_args+=(--exclude "$pattern")
    done
    for ignore_file in "${ignore_files[@]}"; do
      rsync_args+=(--exclude-from "$ignore_file")
    done
    rsync "${rsync_args[@]}" "$REPO"/ "$USER@$HOST:$REMOTE_DIR/current/"
  else
    local tar_args=(-C "$REPO")
    local pattern ignore_file
    for pattern in "${default_excludes[@]}"; do
      tar_args+=(--exclude "$pattern")
    done
    for ignore_file in "${ignore_files[@]}"; do
      tar_args+=(--exclude-from "$ignore_file")
    done
    tar "${tar_args[@]}" -czf - . | \
      "${SSH[@]}" "tar -C '$REMOTE_DIR/current' -xzf -"
  fi
}

run_step ssh_wait wait_for_ssh
run_step ensure_remote_dns ensure_remote_dns
if [[ "$SKIP_PREPARE" != "1" ]]; then
  run_step prepare_remote prepare_remote_dir
fi
if [[ "$SKIP_UPLOAD" != "1" ]]; then
  run_step upload_source upload_source
fi
PRIMARY="$STRATEGY"

set +e
call_driver "$PRIMARY"
primary_status=$?
set -e

if [[ "$primary_status" == "0" ]]; then
  write_result "success" "$PRIMARY" "" "deployment completed"
  emit_event deploy success 0 "strategy $PRIMARY completed"
  exit 0
fi

emit_event deploy failed 0 "primary strategy $PRIMARY failed with exit code $primary_status"

write_result "failed" "$PRIMARY" "" "deployment strategy failed and no viable fallback was available"
exit "$primary_status"
