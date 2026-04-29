#!/bin/bash
# mybox29 一键启动脚本
# 凭证获取顺序：KMS API → 本地加密文件 (offline fallback)
#
# 用法:
#   KMS_KEY=<key> ./run.sh                        # 默认 :1.1.0 进 bash
#   KMS_KEY=<key> ./run.sh 1.1.0                  # 指定 tag
#   KMS_KEY=<key> ./run.sh 1.1.0 claude --print "hi"
set -e

: "${KMS_KEY:?需要设 KMS_KEY 环境变量}"

DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-1.1.0}"
shift 2>/dev/null || true

KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"

fetch_kms() {
    local primary="$1"
    curl -sS --max-time 5 "$KMS_URL/api/query?primary=$primary" \
        -H "Authorization: Bearer $KMS_KEY" 2>/dev/null \
        | python3 -c "
import sys,json
try:
  d = json.load(sys.stdin)
  print(d.get('key_data',{}).get('token',''), end='')
except Exception:
  pass
" 2>/dev/null
}

decrypt_local() {
    local primary="$1"
    local file
    case "$primary" in
        claude-oauth-token)            file="$DIR/secrets/oauth_token.enc" ;;
        claude-session-ingress-token)  file="$DIR/secrets/session_ingress_token.enc" ;;
    esac
    [ -f "$file" ] && openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
        -pass "pass:$KMS_KEY" -in "$file" 2>/dev/null
}

get_token() {
    local primary="$1" val
    val=$(fetch_kms "$primary")
    if [ -n "$val" ]; then
        echo "[run.sh] $primary  ← KMS" >&2
        printf '%s' "$val"; return 0
    fi
    val=$(decrypt_local "$primary")
    if [ -n "$val" ]; then
        echo "[run.sh] $primary  ← local encrypted file" >&2
        printf '%s' "$val"; return 0
    fi
    echo "[run.sh] FATAL: cannot resolve $primary" >&2
    exit 1
}

OAUTH=$(get_token claude-oauth-token)
INGRESS=$(get_token claude-session-ingress-token)

exec docker run --rm -it \
    -e CLAUDE_OAUTH_TOKEN="$OAUTH" \
    -e CLAUDE_SESSION_INGRESS_TOKEN="$INGRESS" \
    -v "$PWD:/workspace" \
    "9527cheri/mybox29:$TAG" "$@"
