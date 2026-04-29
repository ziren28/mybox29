# mybox29

> Self-hosted runner for **Claude Code on the Web** — 让 claude.ai 网页发的消息路由到你自己的容器处理。

[![Docker Pulls](https://img.shields.io/docker/pulls/9527cheri/mybox29)](https://hub.docker.com/r/9527cheri/mybox29)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## 它是什么

镜像里包含 Anthropic 内部的 `environment-runner orchestrator` 二进制（已 patch 让外部可用），加上完整多语言开发沙盒（Python 3.11 / Node 22 / Go 1.24 / Java 21 / Ruby 3.3 / Rust 1.94 / Bun 1.3）和 `@anthropic-ai/claude-code` v2.1.123。

容器作为 BYOC (Bring Your Own Compute) worker 注册到 Anthropic 控制平面后，**从 claude.ai 网页发起的、绑定你这个 environment 的 session 会被路由到该容器**，由容器内 claude 进程处理并把回复流回浏览器。

---

## 整体架构（两个对称的 docker 命令）

```
   ┌──── Master Host (你的某个 claude.ai 容器) ────┐
   │  docker run synchome                          │
   │   ├─ cron */10                                │
   │   ├─ 读 /home/claude/.claude/remote/.oauth_*  │
   │   └─ POST KMS                                 │
   └────────────────────┬──────────────────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │   KMS           │ ← oauth_token 永远 fresh
              │   primary=$NAME │   (由 synchome cron 续约)
              └────────┬────────┘
                       │
                       ▼
   ┌──── Worker (任意 VPS) ─────────────────────┐
   │  docker run 9527cheri/mybox29:1.4.0       │
   │   ├─ KMS 拉 oauth                          │
   │   ├─ register-bridge → service_key         │
   │   └─ exec orchestrator                     │
   │       ↑                                    │
   │       └── 接收 claude.ai 网页消息 → 处理   │
   └────────────────────────────────────────────┘
```

**关键发现（实测）**：claude.ai BYOC events API 仅需 `sessionKey` 一个 cookie，CF 不挑战 POST/GET。整个系统不依赖任何 cf_clearance / 浏览器 / playwright。

---

## 部署只需两条 docker 命令

### Step 1：Master Host 启动 synchome（一次性）

在你已经登录的 claude.ai session 里贴一条命令让它执行：

```bash
docker run -d --name synchome --restart unless-stopped \
  -e KMS_API_KEY='<你的KMS密码>' \
  -e SECRET_NAME='<给这台 master 起个名, 一般用 session_id 后段>' \
  -v /home:/home \
  9527cheri/sync-home:latest
```

它会每 10 分钟自动从 `/home/claude/.claude/remote/.oauth_token` 同步到 KMS。详见 [synchome 项目](https://github.com/ziren28/synchome)。

### Step 2：Worker 启动（任意机器）

```bash
docker run -d --name mybox29-worker --restart unless-stopped \
  -e KMS_API_KEY='<同上>' \
  -e SECRET_NAME='<同上>' \
  9527cheri/mybox29:1.4.0
```

容器内 entrypoint 自动：
1. 从 KMS 拉 oauth（synchome 写入的）
2. POST `/v1/environments/bridge` 拿 service_key
3. exec orchestrator 进入 BYOC 模式
4. 持续 long-poll claude.ai，处理网页发来的消息

完。两条命令完整自治。

---

## 跟 worker 直接对话（无浏览器）

```bash
git clone https://github.com/ziren28/mybox29.git && cd mybox29
SESSION_KEY=sk-ant-sid02-... \
SESSION_ID=session_xxxx \
bun chat-final.mjs "你好, 请简述运行环境"
```

`chat-final.mjs` 走纯 BYOC events API，仅需 `sessionKey`，渲染 thinking / text / tool_use / tool_result 四种内容块。

---

## 镜像 tag 体系

| Tag | 用途 |
|---|---|
| `9527cheri/mybox29:1.4.0` ⭐ | Worker 自治模式（KMS + register-bridge 内建） |
| `9527cheri/mybox29:byoc` | 1.4.0 别名 |
| `9527cheri/mybox29:1.3.1` | Worker 手动模式（要求外部传 ENVIRONMENT_SERVICE_KEY） |
| `9527cheri/mybox29:1.2.0` | 通用 + entrypoint（无 binary patch） |
| `9527cheri/mybox29:1.1.0` / `:env` | 仅 `claude --print` 独立调用 |
| `9527cheri/sync-home:latest` | **Master 端** token 自动同步到 KMS |

---

## 镜像内置环境

| 类目 | 版本 |
|---|---|
| OS | Ubuntu 24.04 |
| Languages | Python 3.11 · Node 22 · Go 1.24 · Java 21 · Ruby 3.3 · Rust 1.94 · Bun 1.3 |
| Build | Maven 3.9 · Gradle 8.14 · Make · CMake · Conan |
| DB tools | PostgreSQL 16 · Redis 7 · SQLite 3 |
| Container | Docker CE 29.3.1（CLI + buildx + compose） |
| Browser | Playwright 1.56 + Chromium 1194 |
| npm 全局 | typescript · prettier · eslint · pnpm · yarn · ts-node · nodemon · serve |
| Anthropic | `@anthropic-ai/claude-code` v2.1.123 + `environment-manager` (semver-patched) |

---

## 文件清单

```
.
├── README.md                    本文件
├── Dockerfile                   sanitization + entrypoint + binary patch
├── entrypoint.sh                ★ KMS 自治模式 + 独立调用 + worker 三合一入口
├── LICENSE                      MIT
│
├── ★ 推荐用法（纯 docker）
│   └── 直接运行 9527cheri/mybox29:1.4.0
│
├── chat-final.mjs               ★ 纯 CLI 跟 worker 对话（仅需 sessionKey）
├── run-worker-final.sh          ★ 高级用法: 外部编排 + watchdog
│
├── 备选 / 历史
│   ├── chat.mjs                 老版 chat 客户端
│   ├── run-master-worker.sh     v1 master-host 浏览器 cookie 路径
│   ├── run-bridge.sh            v0 单机手动 register-bridge
│   ├── register-bridge.sh       一次性 register-bridge 工具
│   ├── alert-via-session.sh     反向 POST 提醒到 master session
│   └── token-sync/              单次同步容器（被 synchome 取代）
│
└── 离线兜底（KMS 故障时）
    ├── refresh.html             浏览器 bookmarklet 上传 sessionKey
    ├── secrets/oauth_token.enc           AES-256-CBC + PBKDF2(200K) 加密
    └── secrets/session_ingress_token.enc
```

---

## Token 链（全自动）

| 层 | 名称 | 寿命 | 谁更新 |
|---|---|---|---|
| L0 | `KMS_API_KEY` | 永久 | 你（一次性） |
| L1 | `oauth-token` | ~10 min | **synchome cron** 每 10 分钟同步 |
| L2 | `service-key` | 30 min+ | Worker 内部 register-bridge |
| L3 | `session_ingress_token` | session 内 | BYOC 协议管理 |

只要 master host 的 synchome 容器还在跑，token 永不过期。

---

## 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| Worker 持续 401/403 | service_key 过期 | watchdog 自动重新 register-bridge（拉新 oauth） |
| KMS 里 token 时间戳不更新 | synchome 容器挂了 | 在 master 重启 `docker restart synchome` |
| Master cookie 失效 | sessionKey 过期（90 天 TTL） | 浏览器 F12 重新导出，更新 chat-final 环境变量 |
| `register-bridge 403 (scope)` | OAuth 不在 master-host 范围 | 确保 SECRET_NAME 对应 master host 的 oauth |
| `Environment runner version not valid semver` | 用了原版 binary | 用 `:1.3.1` 或 `:1.4.0` 镜像（内置 patched） |

---

## 核心实现要点（实战发现）

| 发现 | 详情 |
|---|---|
| `cf_clearance` 不需要 | claude.ai BYOC events API 仅 `sessionKey` 一个 cookie 即可 POST/GET |
| events POST 必须 `session_` 前缀 | `cse_xxx` 被服务端拒绝 |
| 关键 beta header | `ccr-byoc-2025-07-29` + `environments-2025-11-01` |
| Bridge 注册响应 | `environment_id` / `organization_uuid` / `environment_secret` |
| Binary version patch | `release-b5ac58d65-ext` → `2.1.123-b5ac58d65-ext`（21B 等长替换） |
| 浏览器无 OAuth | claude.ai 前端用 cookie auth；OAuth 由 Anthropic 后端 fd 注入 cloud worker |
| BYOC 双向通信 | POST `/v1/sessions/{id}/events` 写消息；GET 同路径轮询读 |

---

## License

MIT
