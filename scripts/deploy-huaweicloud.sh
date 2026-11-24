#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/.env.deploy"
IMAGE="jiuyu-yundang-api:latest"
CONTAINER="jiuyu-yundang-api"

if [ ! -f "$CONFIG" ]; then
  echo "缺少 $CONFIG，请先复制 .env.deploy.example 并填写 ECS 信息。"
  exit 1
fi

set -a
source "$CONFIG"
set +a

: "${ECS_HOST:?请在 .env.deploy 中设置 ECS_HOST}"
: "${SSH_USER:?请在 .env.deploy 中设置 SSH_USER}"
: "${SSH_KEY_PATH:?请在 .env.deploy 中设置 SSH_KEY_PATH}"
: "${REMOTE_DIR:?请在 .env.deploy 中设置 REMOTE_DIR}"

if [ ! -f "$ROOT/.env" ]; then
  echo "缺少 $ROOT/.env，请先复制 .env.example 并填写 RDS/Redis/OBS/大模型配置。"
  exit 1
fi

SSH="ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no $SSH_USER@$ECS_HOST"

echo "[1/4] 构建镜像..."
docker build -t "$IMAGE" "$ROOT"

echo "[2/4] 上传镜像到 ECS..."
docker save "$IMAGE" | gzip | $SSH "docker load"

echo "[3/4] 上传运行环境配置..."
$SSH "mkdir -p \"$REMOTE_DIR\""
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$ROOT/.env" "$SSH_USER@$ECS_HOST:$REMOTE_DIR/.env"

echo "[4/4] 重启容器..."
$SSH "docker stop $CONTAINER 2>/dev/null || true; docker rm $CONTAINER 2>/dev/null || true; docker run -d --name $CONTAINER --restart unless-stopped --env-file $REMOTE_DIR/.env -p 3000:3000 $IMAGE"

echo "部署完成：http://$ECS_HOST:3000"
echo "请到华为云 ECS 安全组放行 3000 端口，或在 ELB/Nginx 后配置域名与 HTTPS。"
