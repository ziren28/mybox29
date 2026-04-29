#!/bin/bash
# mybox29 watchdog v2 — service_key 失效时主动通过 webhook 通知，
# 然后轮询 KMS 等用户上传新 sessionKey，再自动续约 service_key + restart worker
#
# 必需环境变量:
#   KMS_KEY                  - KMS API key (读)
#   KMS_ADMIN_PASSWORD       - KMS admin password (写)
#   ALERT_WEBHOOK            - 通知 URL (e.g. Telegram bot / Slack incoming webhook / Discord)
#   ALERT_TEMPLATE           - 可选：通知 JSON 模板（默认 generic text）
#
# 部署：
#   docker run -d --name mybox29-watchdog \
#     -e KMS_KEY=Aa112211 -e KMS_ADMIN_PASSWORD=Aa112211 \
#     -e ALERT_WEBHOOK="https://api.telegram.org/bot<TOKEN>/sendMessage" \
#     -v /var/run/docker.sock:/var/run/docker.sock \
#     -v $PWD:/repo \
#     9527cheri/mybox29:1.3.1 \
#     /repo/watchdog-v2.sh

set -euo pipefail
: "${KMS_KEY:?}"
: "${KMS_ADMIN_PASSWORD:?}"
: "${ALERT_WEBHOOK:?}"

CONTAINER="${CONTAINER:-mybox29-runner}"
KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
REFRESH_URL="${REFRESH_URL:-https://your-domain/mybox29/refresh.html}"
DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "$(date -u +%FT%TZ) [watchdog] $*"; }

notify() {
    local msg="$1"
    log "alert: $msg"
    curl -sS -X POST "$ALERT_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"text\": $(jq -Rs <<<"$msg")}" >/dev/null || true
}

session_key_hash() {
    curl -fsS "$KMS_URL/api/query?primary=claude-session-key" \
        -H "Authorization: Bearer $KMS_KEY" 2>/dev/null \
        | jq -r '.key_data.token // empty' | sha256sum | cut -c1-12
}

is_unhealthy() {
    docker logs --tail 20 --since 2m "$CONTAINER" 2>&1 \
        | grep -qE '"status_code":(401|403)|unauthorized|auth.*fail|Invalid token'
}

while true; do
    if is_unhealthy; then
        OLD=$(session_key_hash)
        notify "🔴 mybox29-runner token expired. Refresh now: $REFRESH_URL"

        log "waiting for sessionKey update in KMS (current hash: $OLD)…"
        for i in $(seq 1 60); do  # 最多 30 分钟
            sleep 30
            NEW=$(session_key_hash)
            if [ "$NEW" != "$OLD" ] && [ -n "$NEW" ]; then
                log "sessionKey changed (hash $OLD → $NEW)"
                # 用 sessionKey 拿 OAuth → 注册 bridge → 拿 service_key
                # （这里假设有 sessionKey-to-OAuth 换发逻辑；当前简化为：让 host 端再跑 register-bridge）
                # TODO: 实现 sessionKey → OAuth token 自动换发
                docker restart "$CONTAINER" >/dev/null && log "container restarted"
                notify "✅ mybox29-runner recovered, sessionKey rotated"
                break
            fi
            log "  poll $i/60 — still old"
        done
    else
        log "healthy"
    fi
    sleep 60
done
