#!/bin/bash
# mybox29 容器入口脚本（v1.2.0：支持作为 Claude Code self-hosted runner 启动）
set -e

INIT_FLAG=/var/lib/mybox29-initialized

if [ ! -f "$INIT_FLAG" ]; then
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -A >/dev/null 2>&1 || true
    fi

    if [ ! -s /etc/machine-id ]; then
        cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id
    fi
    mkdir -p /var/lib/dbus
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    mkdir -p /workspace
    touch "$INIT_FLAG"
fi

# ── Claude OAuth/Ingress 凭证注入（独立调用模式用） ─────────────
CLAUDE_REMOTE_DIR=/home/claude/.claude/remote
mkdir -p "$CLAUDE_REMOTE_DIR" && chmod 700 "$CLAUDE_REMOTE_DIR"

write_token() {
    if [ -n "$1" ]; then
        printf '%s' "$1" > "$2"
        chmod 600 "$2"
    fi
    return 0
}
write_token "$CLAUDE_OAUTH_TOKEN"            "$CLAUDE_REMOTE_DIR/.oauth_token"
write_token "$CLAUDE_SESSION_INGRESS_TOKEN"  "$CLAUDE_REMOTE_DIR/.session_ingress_token"
[ -r /run/secrets/claude_oauth_token ]            && cp /run/secrets/claude_oauth_token            "$CLAUDE_REMOTE_DIR/.oauth_token" && chmod 600 "$CLAUDE_REMOTE_DIR/.oauth_token"
[ -r /run/secrets/claude_session_ingress_token ]  && cp /run/secrets/claude_session_ingress_token  "$CLAUDE_REMOTE_DIR/.session_ingress_token" && chmod 600 "$CLAUDE_REMOTE_DIR/.session_ingress_token"

# ── 可选 daemon ──
[ "${START_POSTGRES:-0}" = "1" ] && pg_ctlcluster 16 main start >/dev/null 2>&1 || true
[ "${START_REDIS:-0}"    = "1" ] && redis-server --daemonize yes --bind 0.0.0.0 --protected-mode no >/dev/null 2>&1 || true
[ "${START_DOCKER:-0}"   = "1" ] && [ ! -S /var/run/docker.sock ] && (dockerd >/var/log/dockerd.log 2>&1 &) || true

# ── ★ BYOC 自治模式 ★ ────────────────────────────────────────────
# 设 KMS_API_KEY + SECRET_NAME → 容器自己从 KMS 拉 oauth 并 register-bridge
if [ -n "${KMS_API_KEY:-}" ] && [ -n "${SECRET_NAME:-}" ]; then
    KMS_URL="${KMS_URL:-https://kms-admin-4lo.pages.dev}"
    BRIDGE_ENV_ID="${BRIDGE_ENV_ID:-env_0148CCLDzQdWNE2cPRThecmr}"

    log() { echo "$(date -u +%FT%TZ) [byoc] $*"; }

    fetch_oauth() {
        local admin
        admin=$(curl -fsS -X POST "$KMS_URL/api/login" \
            -H 'Content-Type: application/json' \
            -d "{\"password\":\"$KMS_API_KEY\"}" | jq -r .token) || return 1
        [ -z "$admin" ] || [ "$admin" = "null" ] && return 1
        curl -fsS "$KMS_URL/api/secrets?primary=$SECRET_NAME" \
            -H "Authorization: Bearer $admin" | \
            jq -r --arg p "$SECRET_NAME" '.items[] | select(.primary==$p) | .key_data[".oauth_token"]'
    }

    register_bridge() {
        curl -fsS -X POST "https://api.anthropic.com/v1/environments/bridge" \
            -H "Authorization: Bearer $1" \
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

    log "fetch oauth from KMS (primary=$SECRET_NAME)"
    OAUTH=$(fetch_oauth) || { log "KMS fetch failed"; exit 1; }
    [ -z "$OAUTH" ] && { log "no oauth at primary=$SECRET_NAME (ensure synchome runs on master)"; exit 1; }
    log "got oauth (${#OAUTH}B), register-bridge..."

    RESP=$(register_bridge "$OAUTH") || { log "register-bridge failed"; exit 1; }
    ENVIRONMENT_SERVICE_KEY=$(echo "$RESP" | jq -r .environment_secret)
    ENVIRONMENT_ID=$(echo "$RESP" | jq -r .environment_id)
    ORGANIZATION_ID=$(echo "$RESP" | jq -r .organization_uuid)
    [ -z "$ENVIRONMENT_SERVICE_KEY" ] || [ "$ENVIRONMENT_SERVICE_KEY" = "null" ] && {
        log "no service_key in resp: $RESP"; exit 1
    }
    export ENVIRONMENT_SERVICE_KEY ENVIRONMENT_ID ORGANIZATION_ID
    log "got service_key (${#ENVIRONMENT_SERVICE_KEY}B) for env=$ENVIRONMENT_ID — falling through to orchestrator"
fi

# ── ★ Self-hosted runner 模式 ★ ──────────────────────────────────
# 如果设了 ENVIRONMENT_SERVICE_KEY，启动 orchestrator 接管 Claude.ai 网页发来的会话
if [ -n "$ENVIRONMENT_SERVICE_KEY" ]; then
    echo "[mybox29] 启动 self-hosted runner（orchestrator 模式）"
    echo "[mybox29] environment_id=${ENVIRONMENT_ID:-<auto whoami>}"
    echo "[mybox29] organization_id=${ORGANIZATION_ID:-<auto whoami>}"

    ARGS=(orchestrator)
    [ -n "$ENVIRONMENT_ID"  ] && ARGS+=(--environment-id  "$ENVIRONMENT_ID")
    [ -n "$ORGANIZATION_ID" ] && ARGS+=(--organization-id "$ORGANIZATION_ID")
    [ "${SANDBOX_BACKEND:-none}" = "none" ] && ARGS+=(--sandbox-backend none)
    [ "${SKIP_GIT_CONFIG:-1}" = "1" ] && ARGS+=(--skip-git-config)

    cd /workspace
    exec /usr/local/bin/environment-manager "${ARGS[@]}"
fi

# ── 否则进入交互/CLI 模式 ──
if [ -t 0 ] && [ -t 1 ] && [ -z "$MYBOX_QUIET" ]; then
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════════════╗
║                       Welcome to mybox29                         ║
║              Ubuntu 24.04 · Polyglot Dev Sandbox                 ║
╠══════════════════════════════════════════════════════════════════╣
║  Python 3.11  ·  Node 22    ·  Go 1.24   ·  Java 21              ║
║  Ruby 3.3     ·  Rust 1.94  ·  Bun 1.3                           ║
║  Build:  Maven · Gradle · Make · CMake · Conan                   ║
║  Tools:  Git · Docker CLI · psql · redis-cli · sqlite3           ║
║  Claude: claude --print "..."   (auto-detect creds)              ║
╠══════════════════════════════════════════════════════════════════╣
║  独立调用模式: -e CLAUDE_OAUTH_TOKEN/CLAUDE_SESSION_INGRESS_TOKEN ║
║  Worker 模式:  -e ENVIRONMENT_SERVICE_KEY=esk_...                ║
║                (claude.ai/settings 创建 self-hosted environment) ║
╚══════════════════════════════════════════════════════════════════╝
BANNER
fi

cd /workspace 2>/dev/null || cd /root
exec "$@"
