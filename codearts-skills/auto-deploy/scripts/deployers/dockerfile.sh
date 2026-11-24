#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
parse_common_args "$@"

set +e
run_step install_runtime install_docker_remote
status=$?
[[ "$status" == "0" ]] || exit "$status"
set -e

docker_build() {
  local prefix build_arg="" timeout_seconds
  prefix="$(remote_common_prefix)"
  timeout_seconds="$(docker_build_timeout)"
  if [[ -n "$IMAGE_REGISTRY_PREFIX" ]]; then
    build_arg="--build-arg AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX=$(printf '%q' "$IMAGE_REGISTRY_PREFIX")"
  fi
  optimize_dockerfiles_for_cache || true
  remote_bash "$prefix
    export DOCKER_BUILDKIT=1
    if [ -n '$build_arg' ] && ! grep -E 'ARG +AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX|AUTO_DEPLOY_IMAGE_REGISTRY_PREFIX' Dockerfile >/dev/null 2>&1; then
      echo '[auto-deploy] warning: image registry prefix build arg is being passed, but Dockerfile does not appear to consume it'
    fi
    echo '[auto-deploy] building Docker image; first base-image pull can be slow on a cold ECS cache'
    echo '[auto-deploy] docker build timeout: ${timeout_seconds}s'
    set +e
    timeout ${timeout_seconds} sudo -E docker build --progress=plain $build_arg -t '$APP_NAME:latest' . 2>&1
    build_status=\$?
    if [ \"\$build_status\" -eq 124 ]; then
      echo '[auto-deploy] docker build timed out; retrying once to reuse partially downloaded layers'
      timeout ${timeout_seconds} sudo -E docker build --progress=plain $build_arg -t '$APP_NAME:latest' . 2>&1
      build_status=\$?
    fi
    set -e
    if [ \"\$build_status\" -ne 0 ]; then
      if [ \"\$build_status\" -eq 124 ]; then
        echo 'docker build timed out after retry (${timeout_seconds}s each)'
      else
        echo 'docker build failed (exit code: '\$build_status')'
      fi
      exit 22
    fi"
}

docker_start() {
  local prefix
  prefix="$(remote_common_prefix)"
  install_remote_env_file
  remote_bash "$prefix
    sudo docker rm -f '$APP_NAME' >/dev/null 2>&1 || true
    sudo docker run -d --name '$APP_NAME' --restart unless-stopped --env-file '$REMOTE_ENV_FILE' -p '$PORT:$PORT' '$APP_NAME:latest'"
}

set +e
run_step build docker_build
status=$?
[[ "$status" == "0" ]] || exit "$status"
run_step start_service docker_start
status=$?
[[ "$status" == "0" ]] || exit "$status"
set -e
