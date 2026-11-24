#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify.sh --analysis JSON (--resources resource-info.json | --host HOST --user USER --key KEY) [--app-name NAME]
EOF
}

HOST="" USER="" KEY="" ANALYSIS="" APP_NAME="" RESOURCES="" STRATEGY_OVERRIDE="" APP_PORT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --analysis) ANALYSIS="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --resources) RESOURCES="$2"; shift 2 ;;
    --strategy) STRATEGY_OVERRIDE="$2"; shift 2 ;;
    --app-port) APP_PORT_OVERRIDE="$2"; shift 2 ;;
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

[[ -f "$ANALYSIS" && -n "$HOST" && -n "$USER" && -f "$KEY" ]] || { usage >&2; exit 2; }
chmod 600 "$KEY" || true

json_get() {
  python3 - "$ANALYSIS" "$1" <<'PY'
import json, sys
data=json.load(open(sys.argv[1], encoding="utf-8-sig"))
print(data.get(sys.argv[2], ""))
PY
}

APP_NAME="${APP_NAME:-$(json_get app_name)}"
APP_NAME="${APP_NAME:-app}"
PORT="${APP_PORT_OVERRIDE:-$(json_get listen_port)}"
HEALTH="$(json_get health_endpoint)"
STRATEGY="${STRATEGY_OVERRIDE:-$(json_get deploy_strategy)}"
KNOWN_HOSTS="${KEY}.known_hosts"
SSH=(ssh -i "$KEY" -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$USER@$HOST")

"${SSH[@]}" "set -e
case '$STRATEGY' in
  docker|dockerfile)
    sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E '(^|_)$APP_NAME|$APP_NAME' || sudo docker ps
    ;;
  docker-compose)
    sudo docker ps --format '{{.Names}} {{.Status}}' | grep -E '(^|_)$APP_NAME|$APP_NAME|backend|frontend' || sudo docker ps
    ;;
  *)
    systemctl is-active '$APP_NAME'
    ;;
esac
ss -tlnp | grep ':$PORT ' >/dev/null
ok=0
for i in 1 2 3; do
  for path in '$HEALTH' /health /healthz /api/health /; do
    [ -n "\$path" ] || continue
    if curl -fsS "http://localhost:$PORT\$path" >/dev/null; then ok=1; break; fi
  done
  [ "\$ok" = 1 ] && break
  sleep 5
done
[ \"\$ok\" = 1 ]
DISK=\$(df -P / | awk 'NR==2 {gsub(\"%\", \"\", \$5); print \$5}')
MEM=\$(free | awk '/Mem:/ {printf \"%d\", (\$3/\$2)*100}')
echo '{'
echo '  \"app_name\": \"$APP_NAME\",'
echo '  \"url\": \"http://$HOST:$PORT\",'
echo '  \"health_endpoint\": \"$HEALTH\",'
echo '  \"strategy\": \"$STRATEGY\",'
echo '  \"service_state\": \"running\",'
echo '  \"disk_used_percent\": '\"\$DISK\"','
echo '  \"memory_used_percent\": '\"\$MEM\"
echo '}'
if [ \"\$DISK\" -gt 80 ] || [ \"\$MEM\" -gt 80 ]; then echo 'warning: resource usage above 80%' >&2; fi"
