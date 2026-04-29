# mybox29

> 开箱即用的多语言开发沙盒镜像，基于 Ubuntu 24.04，预装完整工具链，支持运行 Anthropic Claude Code。

[![Docker Pulls](https://img.shields.io/docker/pulls/9527cheri/mybox29)](https://hub.docker.com/r/9527cheri/mybox29)
[![Image Size](https://img.shields.io/docker/image-size/9527cheri/mybox29/1.1.0)](https://hub.docker.com/r/9527cheri/mybox29)

## 特点

- **多语言**：Python 3.11 · Node.js 22 · Go 1.24 · Java 21 · Ruby 3.3 · Rust 1.94 · Bun 1.3
- **构建工具**：Maven 3.9 · Gradle 8.14 · Make · CMake · Conan
- **数据库客户端**：PostgreSQL 16 · Redis 7 · SQLite 3
- **可选服务**：通过环境变量一键启动内置 PostgreSQL / Redis / Docker daemon
- **Claude Code**：v2.1.123 已内嵌，凭证通过环境变量注入即可使用
- **零特权基础**：默认非特权运行；仅在启用嵌套 Docker 时需要 `--privileged`

## 镜像 Tag 体系

| Tag | 用途 | 推荐度 |
|---|---|---|
| `9527cheri/mybox29:1.1.0` | 通用清洗版 + 凭证环境变量注入 | ⭐ 推荐 |
| `9527cheri/mybox29:env`   | `1.1.0` 的别名 | 同上 |
| `9527cheri/mybox29:1.0.0` | 通用清洗版（仅支持 `-v` 挂载凭证） | 较旧 |
| `9527cheri/mybox29:generic` | `1.0.0` 别名 | 同上 |

## 快速开始

### 1. 最简启动（仅工具链，不用 Claude Code）

```bash
docker run -it --rm 9527cheri/mybox29:1.1.0
```

### 2. 持久化工作区

```bash
docker run -it --rm \
  -v $PWD:/workspace \
  9527cheri/mybox29:1.1.0
```

### 3. 启用 Claude Code（环境变量注入凭证）

```bash
docker run -it --rm \
  -e CLAUDE_OAUTH_TOKEN="$YOUR_OAUTH_TOKEN" \
  -e CLAUDE_SESSION_INGRESS_TOKEN="$YOUR_INGRESS_TOKEN" \
  9527cheri/mybox29:1.1.0 \
  claude --print "你能正常工作吗？"
```

> 凭证文件位置（如来自现有 Claude Code on the Web 主机）：
> ```
> /home/claude/.claude/remote/.oauth_token
> /home/claude/.claude/remote/.session_ingress_token
> ```

### 4. 启用内置 PostgreSQL + Redis

```bash
docker run -it --rm \
  -p 5432:5432 -p 6379:6379 \
  -e START_POSTGRES=1 -e START_REDIS=1 \
  9527cheri/mybox29:1.1.0
```

### 5. 嵌套 Docker（Docker-in-Docker）

```bash
docker run -it --rm --privileged \
  -e START_DOCKER=1 \
  9527cheri/mybox29:1.1.0
```

## 环境变量

| 变量 | 默认值 | 作用 |
|---|---|---|
| `CLAUDE_OAUTH_TOKEN` | — | OAuth token，注入后 entrypoint 自动落盘 |
| `CLAUDE_SESSION_INGRESS_TOKEN` | — | Session ingress token，配合 OAuth 一起使用 |
| `START_POSTGRES` | `0` | 设 `1` 启动 PostgreSQL 16（端口 5432） |
| `START_REDIS` | `0` | 设 `1` 启动 Redis 7（绑 0.0.0.0、关 protected-mode） |
| `START_DOCKER` | `0` | 设 `1` 启动嵌套 dockerd（需 `--privileged`） |
| `MYBOX_QUIET` | unset | 任意值即跳过欢迎 banner |

## 凭证注入优先级

entrypoint 按以下顺序检测凭证，先命中先用：

1. **环境变量** `CLAUDE_OAUTH_TOKEN` / `CLAUDE_SESSION_INGRESS_TOKEN`
2. **Docker secret** `/run/secrets/claude_oauth_token` / `claude_session_ingress_token`
3. **文件挂载** `-v /any/path:/home/claude/.claude/remote`

任意一种就能启动，无需重建镜像。

## 安全说明

⚠️ **永远不要把明文凭证写进 Dockerfile 或 push 进镜像/仓库**。

镜像设计为**通用、可分发**：默认不含任何用户凭证。容器化的"原子复刻"个人镜像（如 `:latest`、`:atomic-clone-*`）含敏感数据，仅供个人使用，**请勿公开使用**。

## 多机同步

仓库提供两套互为兜底的凭证获取方案：

| 方案 | 凭证来源 | 适用场景 |
|---|---|---|
| ⭐ **KMS（在线）** | `https://kms-admin-4lo.pages.dev` | 联网时首选，token 轮转无需 commit |
| 🛟 **加密文件（离线）** | `secrets/*.enc`（AES-256 + PBKDF2 200K iter） | 内网/离线/KMS 故障兜底 |

`run.sh` 自动按上述优先级尝试，单一密钥（你的 KMS key）即可同时承担两种角色。

### 任意机器同步流程

```bash
git clone https://github.com/ziren28/mybox29.git && cd mybox29
export KMS_KEY=<your-kms-api-key>
./run.sh                                # 默认 :1.1.0 进 bash
./run.sh 1.1.0                          # 指定 tag
./run.sh 1.1.0 claude --print "hi"      # 直接执行命令
```

### Token 轮转

**KMS 方案（推荐）** — 在源机器上：

```bash
KMS_ADMIN_TOKEN=$(curl -sS -X POST https://kms-admin-4lo.pages.dev/api/login \
    -H 'Content-Type: application/json' \
    -d '{"password":"<your-admin-password>"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")

curl -sS -X POST https://kms-admin-4lo.pages.dev/api/secrets \
    -H "Authorization: Bearer $KMS_ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"primary\":\"claude-oauth-token\",\"category\":\"claude\",\"key_data\":{\"token\":\"$(cat /home/claude/.claude/remote/.oauth_token)\"}}"
```

更新后所有机器**无需 git pull**，下次 `./run.sh` 自动取新值。

**加密文件方案** — 重新加密 + push：

```bash
openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt \
    -pass "pass:$KMS_KEY" \
    -in /home/claude/.claude/remote/.oauth_token \
    -out secrets/oauth_token.enc
git add secrets/ && git commit -m "rotate oauth token" && git push
```

### 手动取 token（不用 run.sh）

```bash
# 从 KMS
curl -sS "https://kms-admin-4lo.pages.dev/api/query?primary=claude-oauth-token" \
    -H "Authorization: Bearer $KMS_KEY" | jq -r .key_data.token

# 从本地加密文件
./secrets/decrypt.sh oauth      # 输出 OAuth token 到 stdout
./secrets/decrypt.sh ingress    # 输出 Session Ingress token 到 stdout
```

## 构建

本仓库的 `Dockerfile` 基于 `9527cheri/mybox29` 的"原子复刻 base 层"做的清洗 + entrypoint 增强。完整构建流程：

```bash
git clone https://github.com/ziren28/mybox29.git
cd mybox29
docker build -t mybox29:dev .
docker run -it --rm mybox29:dev
```

## 镜像内置工具列表

### 语言运行时

```
Python 3.11.15        /usr/local/bin/python3
Node.js v22.22.2      /opt/node22/bin/node
Go 1.24.7             /usr/local/go/bin/go
Java 21.0.10          /usr/lib/jvm/java-21-openjdk-amd64/bin/java
Ruby 3.3.6            /usr/local/bin/ruby
Rust 1.94.1           /root/.cargo/bin/rustc
Bun 1.3.11            /root/.bun/bin/bun
GCC 13.3.0            /usr/bin/gcc
```

### 构建/开发工具

```
Maven 3.9.11   Gradle 8.14.3   Make   CMake   Conan
Git 2.43.0     Docker 29.3.1 (CLI + buildx + compose)
```

### 全局 npm 包

```
typescript  prettier  eslint  pnpm  yarn  ts-node  nodemon  serve
```

### 数据库工具

```
PostgreSQL 16.13 (server + client)
Redis 7.0.15 (server + client)
SQLite 3
```

### Anthropic Claude Code

```
@anthropic-ai/claude-code  v2.1.123
```

## License

MIT — 见 [LICENSE](./LICENSE)

## ⭐ Worker 模式（`:1.2.0` / `:runner`）— 接管 Claude.ai 网页会话

镜像内置 `environment-runner orchestrator`，可注册为 Claude Code on the Web 的 **self-hosted environment**，让用户在 claude.ai 网页发送的消息**直接路由到你的容器**响应。

### 一次性准备：在 Anthropic 控制台拿 service key

1. 登录 <https://claude.ai/settings>（必须是 organization owner / admin）
2. 创建一个 self-hosted environment
3. 拿到 **`ENVIRONMENT_SERVICE_KEY`**（带 `org:external_poll_sessions` scope）
4. 记下 `environment_id` (`env_01ABC123`) 与 `organization_id` (`org_01XYZ789`)（可选，orchestrator 会通过 whoami 自动发现）

### 启动 worker

```bash
docker run -d --name mybox29-runner \
  -e ENVIRONMENT_SERVICE_KEY="esk_..." \
  -e ENVIRONMENT_ID="env_01ABC123" \
  -e ORGANIZATION_ID="org_01XYZ789" \
  -v /workspace:/workspace \
  --restart unless-stopped \
  9527cheri/mybox29:runner
```

容器启动后会持续轮询 Anthropic API，等待来自 claude.ai 的 session 任务。任务到来时，自动 fork 一个隔离的工作进程跑 `claude` 处理消息，再把回复写回。

### 工作机制

```
claude.ai 网页    ──发消息──▶  api.anthropic.com (work queue)
                                       │
                  poll        ─────────┘
   ┌──────────────────────────────────┐
   │  你的容器 9527cheri/mybox29:1.2.0 │
   │  ENVIRONMENT_SERVICE_KEY=esk_...  │
   │  → environment-runner orchestrator│
   │     ↓ session 任务到来           │
   │  → task-run (fork claude 子进程) │
   │  → 通过 stream-json 实时双向通信  │
   └────────────┬──────────────────────┘
                │ session 输出
                ▼
          claude.ai 网页 显示响应
```

### 验证（不需要正式 service key 也能验证协议层）

```bash
docker run --rm --entrypoint /usr/local/bin/environment-manager \
  -e ENVIRONMENT_SERVICE_KEY="<any-token>" \
  9527cheri/mybox29:1.2.0 \
  orchestrator --sandbox-backend none --log-level debug --skip-git-config
```

如果输出 `whoami request returned status 403` → 网络通、二进制 OK，仅是 token scope 不足  
如果输出 `whoami request returned status 200` → service key 合格，正常进入轮询循环

## 🛰️ 运维手册（Bridge worker 模式）

### 三种 token 全景

| Token | 形态 | 来源 | 寿命 | 何时需要 |
|---|---|---|---|---|
| **OAuth Access Token** | `~108B` | claude.ai 浏览器登录 | 短期，host 自动刷新 | **仅注册/续约** |
| **Environment Service Key** | `sk-ant-oat01-...` | `POST /v1/environments/bridge` 返回 | 长期（直到删除 environment） | **每次 worker 启动** |
| Session Ingress Token | `660B` | claude.ai 登录态 | 短期 | 仅独立 `claude --print` 模式 |

### 流程图

```
[OAuth token]  ─首次/续约─►  POST /v1/environments/bridge
                                     │
                                     ▼
                     [env_id + service_key]  存到 KMS
                                     │
                                     ▼ KMS_KEY 单一秘密
                          ./run-bridge.sh   →  docker run worker
                                     │
                                     ▼
                          poll /v1/environments/work
                                     │
              用户在 claude.ai 网页发消息 → 路由到 worker → 处理
```

### 一次性 setup（host 机器）

```bash
git clone https://github.com/ziren28/mybox29.git && cd mybox29

# 注册 bridge environment 并把所有产物存到 KMS
KMS_KEY=<your-kms-api-key> \
KMS_ADMIN_PASSWORD=<your-kms-admin-password> \
OAUTH_TOKEN=$(cat /home/claude/.claude/remote/.oauth_token) \
  ./register-bridge.sh my-machine
```

成功后 KMS 中存有：
- `claude-bridge-env-id`
- `claude-bridge-org-id`
- `claude-bridge-service-key`

### 任意机器启动 worker

```bash
git clone https://github.com/ziren28/mybox29.git && cd mybox29
export KMS_KEY=<your-kms-api-key>
./run-bridge.sh                # 默认 :1.3.1，--restart unless-stopped
```

### 环境变量（直接 docker run 不用脚本时）

| 变量 | 必需 | 说明 |
|---|---|---|
| `ENVIRONMENT_SERVICE_KEY` | ✅ | bridge 注册返回的 `environment_secret` |
| `ENVIRONMENT_ID` | ✅ | `env_xxx`（whoami 失败时作 fallback） |
| `ORGANIZATION_ID` | ✅ | 组织 UUID |
| `CLAUDE_CODE_ENVIRONMENT_RUNNER_VERSION` | 可选 | semver；镜像内置 binary 已 patch，不用设 |

### Service key 失效（poll 持续 401/403）

```bash
# 在有 OAuth token 的 host 上重新跑（reuse env_id）
KMS_KEY=<...> KMS_ADMIN_PASSWORD=<...> OAUTH_TOKEN=$(cat .../oauth_token) \
  ./register-bridge.sh
# 然后所有 worker 机器：
docker restart mybox29-runner    # 容器启动时自动从 KMS 拉新 service_key
```

### OAuth token 失效（注册脚本 401）

去 claude.ai 浏览器开 devtools，复制 cookie 中的 `sessionKey` 或 `/home/claude/.claude/remote/.oauth_token` 内容，更新 KMS：

```bash
KMS_ADMIN=$(curl -fsS -X POST https://kms-admin-4lo.pages.dev/api/login \
    -H 'Content-Type: application/json' -d '{"password":"<admin>"}' | jq -r .token)
curl -fsS -X POST https://kms-admin-4lo.pages.dev/api/secrets \
    -H "Authorization: Bearer $KMS_ADMIN" -H "Content-Type: application/json" \
    -d "{\"primary\":\"claude-oauth-token\",\"category\":\"claude\",\"key_data\":{\"token\":\"<NEW>\"}}"
```

### 删除 / cleanup environment

如果不再需要 bridge environment：

```bash
curl -X DELETE https://api.anthropic.com/v1/environments/bridge/$ENV_ID \
  -H "Authorization: Bearer $OAUTH_TOKEN" \
  -H "anthropic-beta: ccr-byoc-2025-07-29,environments-2025-11-01"
```
