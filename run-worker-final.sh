#!/bin/bash
# run-worker-final.sh — mybox29 BYOC worker 终极最简版
#
# 配套 synchome (master host 上自治运行) 使用。
# 只需 2~3 个秘密：
#   KMS_API_KEY      KMS 主密码
#   SECRET_NAME      synchome 在 KMS 中的条目名 (一般是 master 的 session_id 后半段)
#   SESSION_KEY      claude.ai 浏览器登录态 (仅在 watchdog 想主动 ping master 时用)
#   MASTER_SESSION   master host 上的 session_id (同上, 选填)
#
# 关键发现 (2026-04-29 实测):
#   - claude.ai BYOC API 只需 sessionKey 一个 cookie, 无需 cf_clearance / __cf_bm
#   - CF 对 /v1/sessions/.../events 的 POST/GET 不挑战, 直接放行
#   - 因此本脚本完全不依赖浏览器/playwright/keeper

set -euo pipefail

# 自动加载同目录 .env (如果存在)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && set -a && . "$SCRIPT_DIR/.env" && set +a

: "${KMS_API_KEY:?需 KMS_API_KEY (在 .env 设置)}"
: "${SECRET_NAME:?需 SECRET_NAME (synchome 写入 KMS 的 primary)}"

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
WORKER_NAME="${WORKER_NAME:-mybox29-runner}"
TAG="${TAG:-1.4.0}"
BRIDGE_ENV_ID="${BRIDGE_ENV_ID:-env_0148CCLDzQdWNE2cPRThecmr}"
ORG_ID="${ORG_ID:-f7e0b9c2-5006-402e-87ca-e26147d218ad}"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120"

log() { echo "$(date -u +%FT%TZ) [worker] $*"; }

kms_admin() {
    curl -fsS -X POST "$KMS_URL/api/login" \
        -H 'Content-Type: application/json' \
        -d "{\"password\":\"$KMS_API_KEY\"}" | jq -r .token
}

fetch_tokens() {
    local admin; admin=$(kms_admin) || return 1
    [ -z "$admin" ] || [ "$admin" = "null" ] && return 1
    curl -fsS "$KMS_URL/api/secrets?primary=$SECRET_NAME" \
        -H "Authorization: Bearer $admin" | \
        jq -r --arg p "$SECRET_NAME" '.items[] | select(.primary==$p) | .key_data | "\(.[".oauth_token"])\t\(.[".session_ingress_token"])\t\(.time)"'
}

register_bridge() {
    local oauth="$1"
    curl -fsS -X POST "https://api.anthropic.com/v1/environments/bridge" \
        -H "Authorization: Bearer $oauth" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: ccr-byoc-2025-07-29,environments-2025-11-01" \
        -H "x-environment-runner-version: 2.1.123" \
        -d "$(jq -n --arg env "$BRIDGE_ENV_ID" '{
            machine_name: ($ENV.HOSTNAME // "mybox29"),
            directory: "/workspace", branch: "main",
            max_sessions: 1, environment_id: $env,
            metadata: {worker_type: "docker_container"}
        }')"
}

# 仅 sessionKey 一个 cookie. 不需要 cf_clearance / __cf_bm.
ping_master() {
    [ -z "${MASTER_SESSION:-}" ] || [ -z "${SESSION_KEY:-}" ] && return 1
    local msg="${1:-docker restart synchome}"
    local uuid; uuid=$(python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    log "ping master: $msg"
    curl -fsS -o /dev/null -X POST "https://claude.ai/v1/sessions/$MASTER_SESSION/events" \
        -H "Cookie: sessionKey=$SESSION_KEY" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: ccr-byoc-2025-07-29" \
        -H "anthropic-client-feature: ccr" \
        -H "anthropic-client-platform: web_claude_ai" \
        -H "x-organization-uuid: $ORG_ID" \
        -H "User-Agent: $UA" \
        --data-raw "{\"events\":[{\"type\":\"user\",\"uuid\":\"$uuid\",\"session_id\":\"$MASTER_SESSION\",\"parent_tool_use_id\":null,\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$msg\"}]}}]}"
}

start_worker() {
    local oauth="$1" resp svc env org
    log "register bridge..."
    resp=$(register_bridge "$oauth") || { log "register-bridge failed"; return 1; }
    svc=$(echo "$resp" | jq -r .environment_secret)
    env=$(echo "$resp" | jq -r .environment_id)
    org=$(echo "$resp" | jq -r .organization_uuid)
    [ -z "$svc" ] || [ "$svc" = "null" ] && { log "no service_key in: $resp"; return 1; }
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
[ -z "$TOKENS" ] && { log "no token at primary=$SECRET_NAME (synchome on master not running?)"; exit 1; }
OAUTH=$(echo "$TOKENS" | cut -f1)
TS=$(echo "$TOKENS" | cut -f3)
log "fetched token (oauth=${#OAUTH}B last_sync=$TS)"

start_worker "$OAUTH"

log "watchdog loop"
while true; do
    sleep 60
    if docker logs --tail 30 --since 2m "$WORKER_NAME" 2>&1 | \
        grep -qE '"status_code":(401|403)|unauthorized|auth.*fail|Invalid token'; then
        log "auth failure detected"
        if ping_master "请执行: docker restart synchome" 2>/dev/null; then
            sleep 10
        else
            log "no master ping configured, waiting for synchome cron..."
            sleep 60
        fi
        TOKENS=$(fetch_tokens) || continue
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
