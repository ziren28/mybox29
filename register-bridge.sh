#!/bin/bash
# 注册一个 bridge environment 并把所有产物存到 KMS。
# 后续容器启动只需 KMS_KEY 一个秘密即可拉到 service key 与 env_id。
#
# 用法（在 host 机器上执行一次）：
#   KMS_KEY=<your-kms-api-key> \
#   KMS_ADMIN_PASSWORD=<your-kms-admin-password> \
#   OAUTH_TOKEN=<from /home/claude/.claude/remote/.oauth_token> \
#     ./register-bridge.sh [machine_name]
#
# 如果 KMS 已有 claude-bridge-env-id，会复用该 environment（rotate service key）。

set -e
: "${KMS_KEY:?需要 KMS_KEY}"
: "${KMS_ADMIN_PASSWORD:?需要 KMS_ADMIN_PASSWORD（写入 KMS 用）}"
: "${OAUTH_TOKEN:?需要 OAUTH_TOKEN（claude.ai web OAuth）}"

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
MACHINE_NAME="${1:-$(hostname)-mybox29}"

# 1. 拿 KMS admin token (用于写)
echo "[1/4] login KMS admin"
ADMIN=$(curl -fsS -X POST "$KMS_URL/api/login" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"$KMS_ADMIN_PASSWORD\"}" | jq -r .token)
[ -z "$ADMIN" ] && { echo "KMS login failed"; exit 1; }

# 2. 看 KMS 是否已有 env_id（复用）
EXISTING=$(curl -fsS "$KMS_URL/api/query?primary=claude-bridge-env-id" \
    -H "Authorization: Bearer $KMS_KEY" 2>/dev/null \
    | jq -r '.key_data.value // empty')
REUSE_ARG=""
[ -n "$EXISTING" ] && {
    echo "[2/4] reuse existing environment_id=$EXISTING"
    REUSE_ARG=",\"environment_id\":\"$EXISTING\""
}

# 3. 注册（或续约）bridge environment
echo "[3/4] POST /v1/environments/bridge"
REG=$(curl -fsS -X POST "https://api.anthropic.com/v1/environments/bridge" \
    -H "Authorization: Bearer $OAUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: ccr-byoc-2025-07-29,environments-2025-11-01" \
    -H "x-environment-runner-version: 2.1.123" \
    -d "{
        \"machine_name\":\"$MACHINE_NAME\",
        \"directory\":\"/workspace\",
        \"branch\":\"main\",
        \"max_sessions\":1,
        \"metadata\":{\"worker_type\":\"docker_container\"}
        $REUSE_ARG
    }")
ENV_ID=$(echo "$REG" | jq -r .environment_id)
ORG_ID=$(echo "$REG" | jq -r .organization_uuid)
SVC_KEY=$(echo "$REG" | jq -r .environment_secret)
echo "  environment_id   = $ENV_ID"
echo "  organization     = $ORG_ID"
echo "  service_key bytes= ${#SVC_KEY}"

# 4. 写回 KMS
echo "[4/4] upsert KMS"
upsert() {
    curl -fsS -X POST "$KMS_URL/api/secrets" \
        -H "Authorization: Bearer $ADMIN" \
        -H "Content-Type: application/json" \
        -d "$1" >/dev/null
}
upsert "{\"primary\":\"claude-bridge-env-id\",\"category\":\"claude\",\"description\":\"Bridge environment ID for self-hosted runner\",\"key_data\":{\"value\":\"$ENV_ID\"}}"
upsert "{\"primary\":\"claude-bridge-org-id\",\"category\":\"claude\",\"description\":\"Anthropic organization UUID\",\"key_data\":{\"value\":\"$ORG_ID\"}}"
upsert "{\"primary\":\"claude-bridge-service-key\",\"category\":\"claude\",\"description\":\"Bridge environment service key (rotate on need)\",\"key_data\":{\"value\":\"$SVC_KEY\"}}"

echo
echo "✅  Done. Now any machine with KMS_KEY=$KMS_KEY can run ./run-bridge.sh"
