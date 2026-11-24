#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
parse_common_args "$@"

[[ -n "$START_COMMAND" && "$START_COMMAND" != "None" ]] || { echo "native deployment requires start_command in analysis" >&2; exit 3; }

BACKEND_SUB=""

detect_backend_sub() {
  if remote_bash "set -e; cd '$REMOTE_DIR/current'; [ ! -f package.json ] && [ ! -f pom.xml ] && [ ! -f requirements.txt ] && [ ! -f go.mod ] && [ ! -f Cargo.toml ] && [ ! -f build.gradle ] && [ ! -f build.gradle.kts ] && ! find . -maxdepth 1 -name '*.csproj' -print -quit | grep -q . && { [ -f backend/pom.xml ] || [ -f backend/requirements.txt ] || [ -f backend/package.json ] || [ -f backend/go.mod ] || [ -f backend/Cargo.toml ] || find backend -maxdepth 2 -name '*.csproj' -print -quit | grep -q .; }" 2>/dev/null; then
    BACKEND_SUB="/backend"
    printf '[auto-deploy][native] monorepo detected; installing runtime in backend/ subdirectory\n' >&2
  fi
}

runtime_dir() {
  printf '%s/current%s' "$REMOTE_DIR" "$BACKEND_SUB"
}

install_node_if_needed() {
  local dir
  dir="$(runtime_dir)"
  if ! remote_bash "if { cd '$dir' && [ -f package.json ]; } || [ -f '$REMOTE_DIR/current/frontend/package.json' ]; then ! command -v node >/dev/null 2>&1; else exit 1; fi" 2>/dev/null; then
    return 0
  fi
  remote_script "$dir" <<SCRIPT
node_url="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
if printf '%s' "${REGION:-}" | grep -q '^cn-'; then
  node_url="https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
fi
echo "[auto-deploy] installing Node.js v${NODE_VERSION} from \${node_url}..."
if curl -fsSL "\${node_url}" | sudo tar -xJ -C /usr/local --strip-components=1 2>/dev/null; then
  echo '[auto-deploy] Node.js installed via precompiled binary'
else
  echo '[auto-deploy] precompiled binary failed; falling back to NodeSource apt...'
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
SCRIPT
}

install_native_runtime() {
  local dir
  detect_backend_sub
  dir="$(runtime_dir)"
  remote_bash "sudo useradd -r -m -s /usr/sbin/nologin deploy >/dev/null 2>&1 || true"

  install_node_if_needed

  if remote_bash "cd '$dir' && [ -f requirements.txt ]" 2>/dev/null; then
    remote_apt_install python3-venv python3-pip
    remote_script "$dir" <<'SCRIPT'
python3 -m venv .venv
. .venv/bin/activate
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt
SCRIPT
  fi

  if remote_bash "cd '$dir' && [ -f pom.xml ]" 2>/dev/null; then
    remote_apt_install openjdk-17-jdk maven
  fi

  if remote_bash "cd '$dir' && { [ -f build.gradle ] || [ -f build.gradle.kts ]; }" 2>/dev/null; then
    remote_apt_install openjdk-17-jdk gradle
    remote_bash "cd '$dir' && [ -f gradlew ] && chmod +x gradlew || true"
  fi

  if remote_bash "cd '$dir' && [ -f go.mod ] && ! command -v go >/dev/null 2>&1" 2>/dev/null; then
    remote_apt_install golang-go
  fi

  if remote_bash "cd '$dir' && [ -f Cargo.toml ] && ! command -v cargo >/dev/null 2>&1" 2>/dev/null; then
    remote_apt_install cargo
  fi

  if remote_bash "cd '$dir' && find . -maxdepth 2 -name '*.csproj' -print -quit | grep -q . && ! command -v dotnet >/dev/null 2>&1" 2>/dev/null; then
    remote_bash "wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/packages-microsoft-prod.deb && sudo dpkg -i /tmp/packages-microsoft-prod.deb"
    remote_apt_install dotnet-sdk-8.0
  fi
}

is_empty_build_command() {
  local value
  value="$(printf '%s' "${BUILD_COMMAND:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -z "$value" || "$value" == "none" || "$value" == "null" ]]
}

npm_install_native() {
  local dir
  dir="$(runtime_dir)"
  remote_script "$dir" <<'SCRIPT'
if [ -f package-lock.json ]; then
  npm ci --registry=https://registry.npmmirror.com
elif [ -f package.json ]; then
  npm install --registry=https://registry.npmmirror.com
else
  echo 'no package.json; skipping npm install'
fi
SCRIPT
}

build_native() {
  local dir build_cmd
  if is_empty_build_command; then
    echo "no build command configured; skipping build"
    return 0
  fi
  dir="$(runtime_dir)"
  build_cmd="$(shell_quote "$BUILD_COMMAND")"
  remote_script "$dir" <<SCRIPT
BUILD_COMMAND=${build_cmd}
if [ -n "\$BUILD_COMMAND" ] && [ "\$BUILD_COMMAND" != 'None' ] && [ "\$BUILD_COMMAND" != 'null' ]; then
  bash -lc "\$BUILD_COMMAND"
else
  echo 'no build command configured; skipping build'
fi
SCRIPT
}

setup_frontend_nginx_if_needed() {
  local fe_dir local_conf
  if ! remote_bash "[ -d '$REMOTE_DIR/current/frontend' ] && { [ -d '$REMOTE_DIR/current/frontend/dist' ] || [ -d '$REMOTE_DIR/current/frontend/build' ]; }" 2>/dev/null; then
    return 0
  fi
  fe_dir="${REMOTE_DIR}/current/frontend"
  if remote_bash "[ -d '$fe_dir/dist' ]" 2>/dev/null; then
    fe_dir="${fe_dir}/dist"
  elif remote_bash "[ -d '$fe_dir/build' ]" 2>/dev/null; then
    fe_dir="${fe_dir}/build"
  fi
  printf '[auto-deploy][native] frontend build found at %s; setting up Nginx\n' "$fe_dir" >&2
  remote_apt_install nginx
  local_conf="$(mktemp)"
  cat >"$local_conf" <<EOF
server {
  listen 80;
  server_name _;
  root ${fe_dir};
  index index.html;
  location /api/ {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
  }
  location /events/ {
    proxy_pass http://127.0.0.1:${PORT}/events/;
    proxy_set_header Host \$host;
    proxy_buffering off;
    proxy_cache off;
  }
  location / {
    try_files \$uri \$uri/ /index.html;
  }
}
EOF
  cat "$local_conf" | remote_install_file "/etc/nginx/sites-available/${APP_NAME}.conf" 644 root root
  rm -f "$local_conf"
  remote_script "" <<SCRIPT
sudo ln -sf /etc/nginx/sites-available/${APP_NAME}.conf /etc/nginx/sites-enabled/${APP_NAME}.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx || true
SCRIPT
}

build_frontend_fullstack_if_allowed() {
  if [[ "$ALLOW_NATIVE_FULLSTACK" != "1" ]]; then
    return 0
  fi
  if ! remote_bash "[ -f '$REMOTE_DIR/current/frontend/package.json' ]" 2>/dev/null; then
    return 0
  fi
  remote_script "$REMOTE_DIR/current/frontend" <<'SCRIPT'
if [ -f package-lock.json ]; then
  npm ci --registry=https://registry.npmmirror.com
else
  npm install --registry=https://registry.npmmirror.com
fi
if node -e "process.exit(require('./package.json').scripts && require('./package.json').scripts.build ? 0 : 1)"; then
  npm run build
else
  echo 'frontend package.json has no build script; skipping frontend build'
fi
SCRIPT
}

start_native() {
  local dir service_workdir local_unit
  dir="$(runtime_dir)"
  service_workdir="$dir"
  install_remote_env_file
  build_frontend_fullstack_if_allowed
  setup_frontend_nginx_if_needed
  remote_bash "sudo chown -R deploy:deploy '$REMOTE_DIR/current'"

  local_unit="$(mktemp)"
  cat >"$local_unit" <<EOF
[Unit]
Description=Auto-Deployed: ${APP_NAME}
After=network.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=${service_workdir}
EnvironmentFile=${REMOTE_ENV_FILE}
Environment=PORT=${PORT}
Environment=ASPNETCORE_URLS=http://0.0.0.0:${PORT}
ExecStart=/bin/bash -lc 'cd ${service_workdir} && if [ -f .venv/bin/activate ]; then . .venv/bin/activate; fi; ${START_COMMAND}'
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  cat "$local_unit" | remote_install_file "/etc/systemd/system/${APP_NAME}.service" 644 root root
  rm -f "$local_unit"
  remote_script "" <<SCRIPT
sudo systemctl daemon-reload
sudo systemctl enable '${APP_NAME}'
sudo systemctl restart '${APP_NAME}'
SCRIPT
}

set +e
run_step install_runtime install_native_runtime
status=$?
[[ "$status" == "0" ]] || exit "$status"
run_step npm_install npm_install_native
status=$?
[[ "$status" == "0" ]] || exit "$status"
run_step build build_native
status=$?
[[ "$status" == "0" ]] || exit "$status"
run_step start_service start_native
status=$?
[[ "$status" == "0" ]] || exit "$status"
set -e
