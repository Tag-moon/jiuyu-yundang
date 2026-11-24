#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
parse_common_args "$@"

set +e
run_step install_runtime install_docker_remote
status=$?
[[ "$status" == "0" ]] || exit "$status"
set -e

compose_build_and_start() {
  local prefix timeout_seconds
  prefix="$(remote_common_prefix)"
  timeout_seconds="$(docker_build_timeout)"
  merge_remote_env_into_compose_env
  local build_args=""
  if [[ "$REGION" == cn-* ]]; then
    build_args="--build-arg MAVEN_MIRROR=https://maven.aliyun.com/repository/public --build-arg NPM_MIRROR=https://registry.npmmirror.com"
  fi

  optimize_dockerfiles_for_cache || true

  remote_bash "$prefix
    export DOCKER_BUILDKIT=1
    export COMPOSE_DOCKER_CLI_BUILD=1
    if docker compose version >/dev/null 2>&1; then
      COMPOSE='docker compose'
      COMPOSE_PROGRESS='--progress=plain'
    else
      COMPOSE='docker-compose'
      COMPOSE_PROGRESS=''
    fi

    # Connectivity test: check mirrors first, then Docker Hub directly.
    echo '[auto-deploy] testing Docker registry connectivity...'
    mirrors_ok=0
    if [ -f /etc/docker/daemon.json ]; then
      configured_mirrors=\$(python3 -c 'import json; d=json.load(open(\"/etc/docker/daemon.json\")); print(\" \".join(d.get(\"registry-mirrors\",[])))' 2>/dev/null || true)
      for mirror_url in \$configured_mirrors; do
        mirror_host=\$(echo \"\$mirror_url\" | sed 's|https://||;s|/.*||')
        if curl -s --connect-timeout 5 \"https://\${mirror_host}/v2/\" >/dev/null 2>&1; then
          echo \"[auto-deploy] mirror \$mirror_host is reachable\"
          mirrors_ok=1
          break
        fi
      done
    fi
    if [ \"\$mirrors_ok\" -eq 0 ]; then
      # Fallback: quick alpine pull test (~3 MB) with 15s timeout.
      echo '[auto-deploy] testing Docker Hub connectivity with alpine:latest pull...'
      if ! timeout 15 sudo \$COMPOSE pull alpine 2>/dev/null && ! timeout 15 sudo docker pull alpine:latest 2>/dev/null; then
        echo 'docker_hub_unreachable: cannot pull alpine:latest within 15 seconds; Docker Hub may be unreachable'
        echo 'hint: configure registry mirrors or deploy to a region with Docker Hub access'
        exit 24
      fi
    fi
    echo '[auto-deploy] Docker registry connectivity OK'

    # Inject Maven/npm mirror env for cn-* regions
    if [ -n '${build_args}' ]; then
      echo 'MAVEN_MIRROR=https://maven.aliyun.com/repository/public' >> .env 2>/dev/null || true
      echo 'NPM_MIRROR=https://registry.npmmirror.com' >> .env 2>/dev/null || true
      if ! grep -R -E 'ARG +(MAVEN_MIRROR|NPM_MIRROR)|MAVEN_MIRROR|NPM_MIRROR' -n -- */Dockerfile Dockerfile >/dev/null 2>&1; then
        echo '[auto-deploy] warning: Docker mirror build args are being passed, but Dockerfile does not appear to consume MAVEN_MIRROR or NPM_MIRROR'
      fi
    fi

    # Pull pre-built images quickly, then build with a longer configurable timeout.
    set +e
    timeout 30 sudo \$COMPOSE pull --ignore-buildable 2>/dev/null
    pull_status=\$?
    set -e
    if [ \"\$pull_status\" -ne 0 ]; then
      echo '[auto-deploy] warning: some images could not be pulled (will build locally)'
    fi

    set +e
    echo '[auto-deploy] building Docker Compose services; first base-image pull can be slow on a cold ECS cache'
    echo '[auto-deploy] docker compose build timeout: ${timeout_seconds}s'
    timeout ${timeout_seconds} sudo \$COMPOSE build \$COMPOSE_PROGRESS ${build_args} 2>&1
    build_status=\$?
    if [ \"\$build_status\" -eq 124 ]; then
      echo '[auto-deploy] docker compose build timed out; retrying once to reuse partially downloaded layers'
      timeout ${timeout_seconds} sudo \$COMPOSE build \$COMPOSE_PROGRESS ${build_args} 2>&1
      build_status=\$?
    fi
    set -e
    if [ \"\$build_status\" -ne 0 ]; then
      if [ \"\$build_status\" -eq 124 ]; then
        echo 'docker compose build timed out after retry (${timeout_seconds}s each)'
      else
        echo 'docker compose build failed (exit code: '\$build_status')'
      fi
      exit 22
    fi
    sudo \$COMPOSE up -d || { echo 'docker compose up failed'; exit 23; }"
}

set +e
run_step build compose_build_and_start
status=$?
[[ "$status" == "0" ]] || exit "$status"
set -e
emit_event start_service success 0 "docker compose services started"
