#!/bin/bash
# 启动 mybox29 bridge worker。从 KMS 拉 service_key/env_id/org_id 后 docker run。
#
# 用法:
#   KMS_KEY=<your-kms-api-key> ./run-bridge.sh [tag]
#
# 默认 tag=1.3.1。容器以 --restart=unless-stopped 持久运行。
# Service key 失效时（poll 长期 401/403）请重新执行 register-bridge.sh 续约。

set -e
: "${KMS_KEY:?需要 KMS_KEY}"

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
TAG="${1:-1.3.1}"
NAME="${MYBOX_NAME:-mybox29-runner}"

fetch() {
    curl -fsS "$KMS_URL/api/query?primary=$1" \
        -H "Authorization: Bearer $KMS_KEY" \
        | jq -r '.key_data.value // .key_data.token // empty'
}

ENV_ID=$(fetch claude-bridge-env-id)
ORG_ID=$(fetch claude-bridge-org-id)
SVC_KEY=$(fetch claude-bridge-service-key)

[ -z "$ENV_ID" ] && { echo "❌ KMS 中无 claude-bridge-env-id；先跑 register-bridge.sh"; exit 1; }
[ -z "$SVC_KEY" ] && { echo "❌ KMS 中无 claude-bridge-service-key"; exit 1; }

echo "[run-bridge] env_id=$ENV_ID org_id=$ORG_ID svc_key_bytes=${#SVC_KEY}"

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --restart=unless-stopped \
    -e ENVIRONMENT_SERVICE_KEY="$SVC_KEY" \
    -e ENVIRONMENT_ID="$ENV_ID" \
    -e ORGANIZATION_ID="$ORG_ID" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    "9527cheri/mybox29:$TAG"

sleep 3
docker logs "$NAME" 2>&1 | tail -8
echo
echo "✅  worker 在跑。docker logs -f $NAME 查看日志。"
