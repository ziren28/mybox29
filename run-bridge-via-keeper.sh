#!/bin/bash
# Worker 启动脚本（依赖主 host-keeper 提供凭证，不需要 KMS）
#
# 用法：
#   KEEPER_URL=http://keeper-host:8080 ./run-bridge-via-keeper.sh
set -e
: "${KEEPER_URL:=http://localhost:8080}"

NAME="${WORKER_NAME:-mybox29-runner}"
TAG="${TAG:-1.3.1}"

# 从 keeper 拉凭证
echo "[worker] fetching credentials from $KEEPER_URL/service-key"
RESP=$(curl -fsS "$KEEPER_URL/service-key")
ENV_ID=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['environment_id'])")
ORG_ID=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['organization_id'])")
SVC_KEY=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['service_key'])")

echo "[worker] env=$ENV_ID  service_key=${#SVC_KEY}B"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --restart=unless-stopped \
    -e ENVIRONMENT_SERVICE_KEY="$SVC_KEY" \
    -e ENVIRONMENT_ID="$ENV_ID" \
    -e ORGANIZATION_ID="$ORG_ID" \
    -e KEEPER_URL="$KEEPER_URL" \
    "9527cheri/mybox29:$TAG"

sleep 3
docker ps --filter name="$NAME" --format "{{.Names}}  {{.Status}}"
echo
echo "✅ worker started. Re-pull from keeper periodically: while true; do sleep 1800; ./run-bridge-via-keeper.sh; done"
