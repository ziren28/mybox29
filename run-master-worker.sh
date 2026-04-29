#!/bin/bash
# Worker 在 Master-Host 架构下的一键启动 + watchdog
#
# 假设 Master-Host (claude.ai 网页 session) 已经按 MASTER-HOST.md 安装好咒语，
# 它会在每次收到消息时把 fresh oauth_token 上传 KMS。
#
# 用法：
#   KMS_KEY=Aa112211 \
#   MASTER_SESSION=session_xxxx \
#   SESSION_KEY=sk-ant-sid02-... \      # 浏览器 cookie 用于 POST events 触发 refresh
#   CF_CLEARANCE=... \
#   ORG_ID=... \
#     ./run-master-worker.sh
set -euo pipefail
: "${KMS_KEY:?需 KMS_KEY}"
: "${MASTER_SESSION:?需 MASTER_SESSION (主 host session_xxxx)}"
: "${SESSION_KEY:?需 SESSION_KEY (用于 POST refresh 给 master)}"
: "${CF_CLEARANCE:?需 CF_CLEARANCE}"
: "${ORG_ID:?需 ORG_ID}"

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
WORKER_NAME="${WORKER_NAME:-mybox29-runner}"
TAG="${TAG:-1.3.1}"

log() { echo "$(date -u +%FT%TZ) [worker] $*"; }

fetch_oauth() {
    curl -fsS "$KMS_URL/api/query?primary=claude-oauth-token" \
        -H "Authorization: Bearer $KMS_KEY" | jq -r '.key_data.token'
}

register_bridge() {
    local oauth="$1"
    local body
    body=$(jq -n --arg env "${BRIDGE_ENV_ID:-env_0148CCLDzQdWNE2cPRThecmr}" '{
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

ask_master_to_refresh() {
    log "asking master ($MASTER_SESSION) to refresh oauth"
    local uuid
    uuid=$(python3 -c "import uuid;print(uuid.uuid4())")
    curl -fsS -X POST "https://claude.ai/v1/sessions/$MASTER_SESSION/events" \
        -H "content-type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: ccr-byoc-2025-07-29" \
        -H "anthropic-client-feature: ccr" \
        -H "anthropic-client-platform: web_claude_ai" \
        -H "x-organization-uuid: $ORG_ID" \
        -H "user-agent: Mozilla/5.0" \
        -H "referer: https://claude.ai/code/$MASTER_SESSION" \
        -b "sessionKey=$SESSION_KEY; cf_clearance=$CF_CLEARANCE; lastActiveOrg=$ORG_ID" \
        --data-raw "{\"events\":[{\"type\":\"user\",\"uuid\":\"$uuid\",\"session_id\":\"$MASTER_SESSION\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"refresh\"}]}}]}" >/dev/null
}

start_worker() {
    local oauth="$1"
    log "register bridge..."
    local resp
    resp=$(register_bridge "$oauth")
    local svc env org
    svc=$(echo "$resp" | jq -r .environment_secret)
    env=$(echo "$resp" | jq -r .environment_id)
    org=$(echo "$resp" | jq -r .organization_uuid)
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
OAUTH=$(fetch_oauth)
[ -z "$OAUTH" ] && { log "no oauth in KMS, asking master first"; ask_master_to_refresh; sleep 15; OAUTH=$(fetch_oauth); }
start_worker "$OAUTH"

log "watchdog loop"
while true; do
    sleep 60
    if docker logs --tail 20 --since 2m "$WORKER_NAME" 2>&1 | \
        grep -qE '"status_code":(401|403)|unauthorized|auth.*fail|Invalid token'; then
        log "auth failure detected, asking master to refresh"
        ask_master_to_refresh
        sleep 20
        OAUTH=$(fetch_oauth)
        if [ -n "$OAUTH" ]; then
            start_worker "$OAUTH"
        else
            log "still no fresh oauth, retry next cycle"
        fi
    else
        log "healthy"
    fi
done
