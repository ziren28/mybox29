#!/bin/bash
# mybox29 容器入口脚本（v1.1.0：支持环境变量注入凭证）
set -e

INIT_FLAG=/var/lib/mybox29-initialized

if [ ! -f "$INIT_FLAG" ]; then
    # ── SSH host keys（每个容器实例独立） ──
    if command -v ssh-keygen >/dev/null 2>&1; then
        ssh-keygen -A >/dev/null 2>&1 || true
    fi

    # ── machine-id ──
    if [ ! -s /etc/machine-id ]; then
        cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id
    fi
    mkdir -p /var/lib/dbus
    ln -sf /etc/machine-id /var/lib/dbus/machine-id

    # ── 工作目录 ──
    mkdir -p /workspace

    touch "$INIT_FLAG"
fi

# ── 凭证注入（每次启动都执行，支持 token 轮转） ──────────────────────
# 优先级：env var > /run/secrets > 已挂载文件
CLAUDE_REMOTE_DIR=/home/claude/.claude/remote
mkdir -p "$CLAUDE_REMOTE_DIR"
chmod 700 "$CLAUDE_REMOTE_DIR"

write_token() {
    local content="$1" target="$2"
    if [ -n "$content" ]; then
        printf '%s' "$content" > "$target"
        chmod 600 "$target"
        return 0
    fi
    return 1
}

# OAuth token（必需）
if [ -n "$CLAUDE_OAUTH_TOKEN" ]; then
    write_token "$CLAUDE_OAUTH_TOKEN" "$CLAUDE_REMOTE_DIR/.oauth_token"
elif [ -r /run/secrets/claude_oauth_token ]; then
    cp /run/secrets/claude_oauth_token "$CLAUDE_REMOTE_DIR/.oauth_token"
    chmod 600 "$CLAUDE_REMOTE_DIR/.oauth_token"
fi

# Session ingress token（必需）
if [ -n "$CLAUDE_SESSION_INGRESS_TOKEN" ]; then
    write_token "$CLAUDE_SESSION_INGRESS_TOKEN" "$CLAUDE_REMOTE_DIR/.session_ingress_token"
elif [ -r /run/secrets/claude_session_ingress_token ]; then
    cp /run/secrets/claude_session_ingress_token "$CLAUDE_REMOTE_DIR/.session_ingress_token"
    chmod 600 "$CLAUDE_REMOTE_DIR/.session_ingress_token"
fi

# ── 可选 daemon ──
[ "${START_POSTGRES:-0}" = "1" ] && pg_ctlcluster 16 main start >/dev/null 2>&1 || true
[ "${START_REDIS:-0}"    = "1" ] && redis-server --daemonize yes --bind 0.0.0.0 --protected-mode no >/dev/null 2>&1 || true
[ "${START_DOCKER:-0}"   = "1" ] && [ ! -S /var/run/docker.sock ] && (dockerd >/var/log/dockerd.log 2>&1 &) || true

# ── 欢迎 banner ──
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
║  Inject creds:  -e CLAUDE_OAUTH_TOKEN=...                        ║
║                 -e CLAUDE_SESSION_INGRESS_TOKEN=...              ║
║  START_POSTGRES=1 / START_REDIS=1 / START_DOCKER=1               ║
║  MYBOX_QUIET=1 to hide this banner                               ║
╚══════════════════════════════════════════════════════════════════╝
BANNER
fi

cd /workspace 2>/dev/null || cd /root
exec "$@"
