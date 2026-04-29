#!/bin/bash
# 一键启动主 host-keeper 容器（cookie → OAuth → service_key 自动维护）
#
# 用法：
#   SESSION_KEY=<sk-ant-sid02-...> \
#   CF_CLEARANCE=<...> \
#   ORG_ID=<org-uuid> \
#     ./run-keeper.sh
set -e
: "${SESSION_KEY:?需要 SESSION_KEY (浏览器 sessionKey cookie)}"
: "${CF_CLEARANCE:?需要 CF_CLEARANCE (浏览器 cf_clearance cookie)}"
: "${ORG_ID:?需要 ORG_ID (organization UUID)}"

NAME="${KEEPER_NAME:-mybox29-keeper}"
PORT="${KEEPER_PORT:-8080}"
TAG="${TAG:-1.3.1}"
DIR="$(cd "$(dirname "$0")" && pwd)"

docker rm -f "$NAME" 2>/dev/null || true

docker run -d --name "$NAME" --restart=unless-stopped \
    -e SESSION_KEY="$SESSION_KEY" \
    -e CF_CLEARANCE="$CF_CLEARANCE" \
    -e ORG_ID="$ORG_ID" \
    -e PORT="$PORT" \
    -p "$PORT:$PORT" \
    -v "$DIR/host-keeper.mjs:/host-keeper.mjs:ro" \
    --entrypoint /opt/node22/bin/node \
    "9527cheri/mybox29:$TAG" \
    /host-keeper.mjs

sleep 3
echo "=== 容器状态 ==="
docker ps --filter name="$NAME" --format "{{.Names}}  {{.Status}}  {{.Ports}}"
echo
echo "=== 日志（前 20 行）==="
docker logs "$NAME" 2>&1 | head -20
echo
echo "✅ keeper 已启动。worker 连 http://${KEEPER_HOST:-localhost}:$PORT 取凭证"
echo "  curl http://localhost:$PORT/healthz"
echo "  curl http://localhost:$PORT/oauth"
echo "  curl http://localhost:$PORT/service-key"
