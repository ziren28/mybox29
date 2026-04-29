#!/bin/bash
# Worker watchdog: 检测 service_key 失效（poll 401/403），自动重新注册 + 重启 worker
# 建议放到 cron: */5 * * * * /path/to/watchdog.sh >> /var/log/mybox29-watchdog.log 2>&1
#
# 需要在环境/cron 里设置：
#   KMS_KEY                   - 你的 KMS API key（读 KMS）
#   KMS_ADMIN_PASSWORD        - 写 KMS 用
# 此脚本会从 KMS 拉 OAuth token 自动续约，不需要交互。

set -euo pipefail
: "${KMS_KEY:?}"
: "${KMS_ADMIN_PASSWORD:?}"

CONTAINER="${CONTAINER:-mybox29-runner}"
LOG_TAIL_LINES=20

# 看最近 docker 日志中是否有 401/403/auth/unauthor 错误
RECENT=$(docker logs --tail $LOG_TAIL_LINES "$CONTAINER" 2>&1 || true)
if echo "$RECENT" | grep -qE '"status_code":(401|403)|unauthorized|auth.*fail'; then
    echo "$(date -u +%FT%TZ) [watchdog] auth failure detected, rotating service_key"

    # 从 KMS 拉 OAuth token
    OAUTH=$(curl -fsS "https://kms-admin-4lo.pages.dev/api/query?primary=claude-oauth-token" \
        -H "Authorization: Bearer $KMS_KEY" | jq -r '.key_data.token')

    DIR="$(cd "$(dirname "$0")" && pwd)"
    KMS_KEY="$KMS_KEY" KMS_ADMIN_PASSWORD="$KMS_ADMIN_PASSWORD" OAUTH_TOKEN="$OAUTH" \
        "$DIR/register-bridge.sh" "$(hostname)" >&2

    docker restart "$CONTAINER"
    echo "$(date -u +%FT%TZ) [watchdog] worker restarted"
else
    echo "$(date -u +%FT%TZ) [watchdog] worker healthy"
fi
