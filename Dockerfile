FROM 9527cheri/mybox29:latest

LABEL org.opencontainers.image.title="mybox29-generic"
LABEL org.opencontainers.image.description="Sanitized, redistributable polyglot dev sandbox derived from atomic clone."
LABEL org.opencontainers.image.source="https://hub.docker.com/r/9527cheri/mybox29"

# ── 私有数据清洗 ──────────────────────────────────────────────
# 单层 RUN，避免每条命令产生新 layer。最后所有删除都会落在同一层。
RUN set -eux; \
    # Anthropic / Claude session 数据
    rm -rf /root/.claude /home/*/.claude /tmp/claude-* /tmp/codesign-mcp-config.json; \
    # Docker 凭证
    rm -rf /root/.docker /home/*/.docker; \
    # 历史与命令记录
    rm -f /root/.bash_history /root/.python_history /root/.psql_history \
          /root/.lesshst /root/.viminfo /root/.wget-hsts /root/.sqlite_history \
          /root/.node_repl_history; \
    rm -rf /home/*/.bash_history /home/*/.python_history; \
    # 缓存
    rm -rf /root/.cache /home/*/.cache /var/cache/apt/archives/*.deb; \
    # SSH host keys（首次启动时由 entrypoint 重新生成）
    rm -f /etc/ssh/ssh_host_*; \
    # machine-id（首次启动时由 entrypoint 生成）
    : > /etc/machine-id; \
    rm -f /var/lib/dbus/machine-id; \
    # PostgreSQL 数据目录（仅保留 cluster 配置，数据让首次 initdb 处理）
    rm -rf /var/lib/postgresql/16/main/*; \
    # 浏览器/工具的 token-bearing 配置（如有）
    rm -rf /root/.config/gh /root/.config/git/credentials \
           /root/.aws /root/.kube /root/.gnupg /root/.npmrc /root/.yarnrc \
           /root/.cargo/credentials* /root/.gem/credentials \
           /root/.gitconfig /root/.git-credentials 2>/dev/null || true; \
    # 临时与日志
    rm -rf /tmp/* /var/tmp/* /var/log/*.log /var/log/*/*.log; \
    # cloud session 残留
    rm -rf /var/run/* /run/*.pid; \
    # 创建工作目录
    mkdir -p /workspace; \
    chmod 1777 /tmp /var/tmp

# ── 入口脚本 ──────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace

ENV MYBOX_VARIANT=generic \
    MYBOX_VERSION=1.1.0

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/bash"]
