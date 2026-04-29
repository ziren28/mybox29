#!/bin/bash
# run-worker-v2.sh — 配套 synchome 的 mybox29 worker 启动器
#
# 前提：master host 上已经在跑 synchome 容器，每 10 分钟自动同步 oauth_token 到 KMS。
# 本脚本职责：
#   1. 从 KMS 拉 oauth_token (synchome 写入的 schema)
#   2. POST /v1/environments/bridge 拿 service_key
#   3. docker run mybox29:1.3.1 进入 BYOC 模式
#   4. watchdog: worker 失效时 → 让 master 执行 `docker restart synchome` → 等新 token → 重启 worker
#
# 必需环境变量：
#   KMS_API_KEY      KMS 主密码
#   SECRET_NAME      KMS 中存 token 的 primary 字段 (e.g. master host 的 session_id)
#
# 选填（仅当需要强制 master 提前同步 token 时才用到）：
#   MASTER_SESSION   master host 上 claude.ai session_id (POST refresh 用)
#   SESSION_KEY      claude.ai sessionKey cookie
#   CF_CLEARANCE     cf_clearance cookie
#   ORG_ID           organization UUID

set -euo pipefail
: "${KMS_API_KEY:?需 KMS_API_KEY}"
: "${SECRET_NAME:?需 SECRET_NAME (synchome 写入 KMS 时用的 primary)}"

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
WORKER_NAME="${WORKER_NAME:-mybox29-runner}"
TAG="${TAG:-1.3.1}"
BRIDGE_ENV_ID="${BRIDGE_ENV_ID:-env_0148CCLDzQdWNE2cPRThecmr}"
ORG_ID="${ORG_ID:-f7e0b9c2-5006-402e-87ca-e26147d218ad}"

log() { echo "$(date -u +%FT%TZ) [worker-v2] $*"; }

kms_login() {
    curl -fsS -X POST "$KMS_URL/api/login" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"$KMS_API_KEY\"}" | jq -r .token
}

fetch_tokens() {
    local admin
    admin=$(kms_login) || return 1
    [ -z "$admin" ] || [ "$admin" = "null" ] && return 1
    curl -fsS "$KMS_URL/api/secrets?primary=$SECRET_NAME" \
        -H "Authorization: Bearer $admin" | \
        jq -r --arg p "$SECRET_NAME" '.items[] | select(.primary==$p) | .key_data | "\(.[".oauth_token"])\t\(.[".session_ingress_token"])\t\(.time)"'
}

register_bridge() {
    local oauth="$1"
    local body
    body=$(jq -n --arg env "$BRIDGE_ENV_ID" '{
        machine_name: ($ENV.HOSTNAME // "mybox29"), directory: "/workspace",
        branch: "main", max_sessions: 1,
        environment_id: $env,
        metadata: {worker_type: "docker_container"}
    }')
    curl -fsS -X POST "https://api.anthropic.com/v1/environments/bridge" \
        -H "Authorization: Bearer $oauth" -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: ccr-byoc-2025-07-29,environments-2025-11-01" \
        -H "x-environment-runner-version: 2.1.123" \
        -d "$body"
}

ask_master_to_restart_synchome() {
    if [ -z "${MASTER_SESSION:-}" ] || [ -z "${SESSION_KEY:-}" ]; then
        log "MASTER_SESSION/SESSION_KEY not set, just waiting for next synchome cron tick (~10min)"
        return 1
    fi
    log "asking master ($MASTER_SESSION) to: docker restart synchome"
    local uuid
    uuid=$(python3 -c "import uuid;print(uuid.uuid4())" 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    curl -fsS -X POST "https://claude.ai/v1/sessions/$MASTER_SESSION/events" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: ccr-byoc-2025-07-29" \
        -H "anthropic-client-feature: ccr" \
        -H "anthropic-client-platform: web_claude_ai" \
        -H "x-organization-uuid: $ORG_ID" \
        -H "user-agent: Mozilla/5.0" \
        -H "referer: https://claude.ai/code/$MASTER_SESSION" \
        -b "sessionKey=$SESSION_KEY; cf_clearance=${CF_CLEARANCE:-}; lastActiveOrg=$ORG_ID" \
        --data-raw "{\"events\":[{\"type\":\"user\",\"uuid\":\"$uuid\",\"session_id\":\"$MASTER_SESSION\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"请执行: docker restart synchome\"}]}}]}" >/dev/null
}

start_worker() {
    local oauth="$1"
    log "register bridge..."
    local resp svc env org
    resp=$(register_bridge "$oauth")
    svc=$(echo "$resp" | jq -r .environment_secret)
    env=$(echo "$resp" | jq -r .environment_id)
    org=$(echo "$resp" | jq -r .organization_uuid)
    [ -z "$svc" ] || [ "$svc" = "null" ] && { log "register-bridge failed: $resp"; return 1; }
    log "got service_key (${#svc}B) for env=$env"

    docker rm -f "$WORKER_NAME" 2>/dev/null || true
    docker run -d --name "$WORKER_NAME" --restart=unless-stopped \
        -e ENVIRONMENT_SERVICE_KEY="$svc" \
        -e ENVIRONMENT_ID="$env" \
        -e ORGANIZATION_ID="$org" \
        "9527cheri/mybox29:$TAG"
    log "worker started"
}

# === 主循环 ===
TOKENS=$(fetch_tokens) || { log "KMS fetch failed"; exit 1; }
[ -z "$TOKENS" ] && { log "no tokens at primary=$SECRET_NAME, ensure synchome is running on master"; exit 1; }
OAUTH=$(echo "$TOKENS" | cut -f1)
INGRESS=$(echo "$TOKENS" | cut -f2)
TS=$(echo "$TOKENS" | cut -f3)
log "fetched tokens (oauth=${#OAUTH}B ingress=${#INGRESS}B, last_sync=$TS)"

start_worker "$OAUTH"

log "watchdog loop"
while true; do
    sleep 60
    if docker logs --tail 30 --since 2m "$WORKER_NAME" 2>&1 | \
        grep -qE '"status_code":(401|403)|unauthorized|auth.*fail|Invalid token'; then
        log "auth failure detected"
        ask_master_to_restart_synchome || true
        log "waiting 15s for synchome to push fresh token..."
        sleep 15
        TOKENS=$(fetch_tokens) || { log "KMS fetch failed in retry"; continue; }
        NEW_OAUTH=$(echo "$TOKENS" | cut -f1)
        NEW_TS=$(echo "$TOKENS" | cut -f3)
        if [ -n "$NEW_OAUTH" ] && [ "$NEW_TS" != "$TS" ]; then
            log "token refreshed ($TS → $NEW_TS), restarting worker"
            OAUTH="$NEW_OAUTH"; TS="$NEW_TS"
            start_worker "$OAUTH"
        else
            log "token not yet refreshed (still $TS), retry next cycle"
        fi
    else
        log "healthy"
    fi
done
