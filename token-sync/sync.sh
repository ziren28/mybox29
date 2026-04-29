#!/bin/sh
# token-sync: 从挂载目录读 Anthropic OAuth token → 上传 KMS
# 运行方式:
#   docker run --rm \
#     -v /home/claude/.claude/remote:/tokens:ro \
#     -e KMS_PASS=Aa112211 \
#     9527cheri/token-sync:latest

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
KMS_PASS="${KMS_PASS:-Aa112211}"
TOKEN_DIR="${TOKEN_DIR:-/tokens}"

die() { echo "❌ $*" >&2; exit 1; }

OAUTH=$(cat "$TOKEN_DIR/.oauth_token" 2>/dev/null) || die ".oauth_token not found at $TOKEN_DIR"
INGRESS=$(cat "$TOKEN_DIR/.session_ingress_token" 2>/dev/null) || die ".session_ingress_token not found at $TOKEN_DIR"
[ -z "$OAUTH" ]   && die ".oauth_token is empty"
[ -z "$INGRESS" ] && die ".session_ingress_token is empty"

ADMIN=$(curl -fsS -X POST "$KMS_URL/api/login" \
    -H 'Content-Type: application/json' \
    -d "{\"password\":\"$KMS_PASS\"}" | jq -r .token) \
    || die "KMS login failed"
[ -z "$ADMIN" ] || [ "$ADMIN" = "null" ] && die "KMS login returned empty token"

curl -fsS -X POST "$KMS_URL/api/secrets" \
    -H "Authorization: Bearer $ADMIN" \
    -H 'Content-Type: application/json' \
    -d "{\"primary\":\"claude-oauth-token\",\"category\":\"claude\",\"key_data\":{\"token\":\"$OAUTH\"}}" \
    || die "failed to upload oauth-token"

curl -fsS -X POST "$KMS_URL/api/secrets" \
    -H "Authorization: Bearer $ADMIN" \
    -H 'Content-Type: application/json' \
    -d "{\"primary\":\"claude-session-ingress-token\",\"category\":\"claude\",\"key_data\":{\"token\":\"$INGRESS\"}}" \
    || die "failed to upload session-ingress-token"

echo "✅ tokens synced at $(date -u +%FT%TZ): oauth=${#OAUTH}B ingress=${#INGRESS}B"
