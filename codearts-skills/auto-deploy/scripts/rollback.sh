#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: rollback.sh (--resources resource-info.json | --host HOST --user USER --key KEY) --app-name NAME [--destroy-spec JSON] [--reason TEXT]
EOF
}

HOST="" USER="" KEY="" APP_NAME="" DESTROY_SPEC="" RESOURCES="" REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --destroy-spec) DESTROY_SPEC="$2"; shift 2 ;;
    --resources) RESOURCES="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "$RESOURCES" ]]; then
  [[ -f "$RESOURCES" ]] || { echo "resource info file not found: $RESOURCES" >&2; exit 2; }
  eval "$(python3 - "$RESOURCES" <<'PY'
import json, shlex, sys
data=json.load(open(sys.argv[1], encoding="utf-8-sig"))
mapping={"HOST": data.get("public_ip"), "USER": data.get("ssh_user"), "KEY": data.get("ssh_key_path")}
for key, value in mapping.items():
    print(f"{key}={shlex.quote(str(value or ''))}")
PY
)"
fi

[[ -n "$HOST" && -n "$USER" && -n "$APP_NAME" && -f "$KEY" ]] || { usage >&2; exit 2; }
chmod 600 "$KEY" || true
KNOWN_HOSTS="${KEY}.known_hosts"
SSH=(ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER@$HOST")
REMOTE_DIR="/opt/auto-deploy/${APP_NAME}"

if ! "${SSH[@]}" "echo ok >/dev/null" 2>/dev/null; then
  echo "rollback skipped: ssh is not reachable for $USER@$HOST" >&2
  echo "Rollback reason: ${REASON:-unspecified failure}" >&2
  exit 0
fi

"${SSH[@]}" "set -e
sudo docker rm -f '$APP_NAME' >/dev/null 2>&1 || true
sudo systemctl stop '$APP_NAME' >/dev/null 2>&1 || true
if [ -d '$REMOTE_DIR/backup.previous' ]; then
  sudo rm -rf '$REMOTE_DIR/current.failed'
  if [ -d '$REMOTE_DIR/current' ]; then sudo mv '$REMOTE_DIR/current' '$REMOTE_DIR/current.failed'; fi
  sudo mv '$REMOTE_DIR/backup.previous' '$REMOTE_DIR/current'
  if systemctl list-unit-files | grep -q '^$APP_NAME.service'; then sudo systemctl restart '$APP_NAME' || true; fi
fi
echo rollback-complete"

if [[ -n "$DESTROY_SPEC" ]]; then
  echo "Resource destroy requested. Use scripts/destroy.py with the recorded Terraform workdir; destroy only state-managed resources." >&2
  cat "$DESTROY_SPEC" >&2
fi

echo "Rollback reason: ${REASON:-unspecified failure}" >&2
