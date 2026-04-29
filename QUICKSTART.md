# mybox29 快速部署 · 三步走

```
┌─────────────┐  cookie  ┌──────────────┐  service_key  ┌─────────────┐
│   你浏览器   │ ───────► │  host-keeper  │ ─────────────►│   worker    │
│ (claude.ai) │          │ (本机/VPS)    │  HTTP/8080    │ (任意机器)   │
└─────────────┘          └──────────────┘               └─────────────┘
```

## 第 1 步：从浏览器导出 cookie

打开 claude.ai 已登录的页面 → F12 → Application/存储 → Cookies → claude.ai

复制三个值：
```
SESSION_KEY     = sk-ant-sid02-xxx           (sessionKey)
CF_CLEARANCE    = xxx-1777xxxxxx-xxx         (cf_clearance)
ORG_ID          = xxxxxxxx-xxxx-xxxx-xxxx    (lastActiveOrg)
```

## 第 2 步：在你本机启动 host-keeper

> ⚠️ **必须在你本机或与浏览器同 IP 的机器上跑** — keeper 用浏览器 fetch claude.ai/v1/environments/bridge，
> Cloudflare 把 cf_clearance 跟 IP/UA fingerprint 绑定，跨 IP 会被挡（HTTP 403）。

```bash
git clone https://github.com/ziren28/mybox29.git && cd mybox29

SESSION_KEY="sk-ant-sid02-..." \
CF_CLEARANCE="..." \
ORG_ID="..." \
  ./run-keeper.sh
```

启动后 keeper 会：
1. 用 playwright 启动 headless chromium
2. 注入你的 cookie，访问 claude.ai/code
3. 在浏览器内 fetch /v1/environments/bridge 注册一个 self-hosted environment
4. 拿到 service_key（`sk-ant-oat01-...`）
5. 暴露 HTTP `:8080`：
   - `GET /healthz`
   - `GET /service-key`     - 拉最新 service_key（自动续约）
   - `POST /rotate-service-key` - 强制现在续一次

## 第 3 步：任意机器（或本机）启动 worker

```bash
KEEPER_URL=http://<keeper-host>:8080 ./run-bridge-via-keeper.sh
```

worker 会：
1. 从 keeper 拉 `service_key + env_id + org_id`
2. `docker run mybox29:1.3.1` 进 orchestrator 模式
3. 持续 long-poll 等用户从 claude.ai 网页发的消息

## Token 维护流程（自动）

| 何时 | 谁做 | 做什么 |
|---|---|---|
| 启动时 | keeper | 浏览器 fetch register-bridge → 拿 service_key |
| 每 30 分钟 | keeper | 自动 re-register（reuse env_id），续 service_key |
| Cookie 过期 | 你 | 重新从浏览器导出，重启 keeper |
| Worker 失效 | worker | 重启自己，重新从 keeper 拉新 service_key |

## 你只需要维护一件事

**让你浏览器里的 claude.ai 保持登录态。**

只要登录态在，cookie 长期有效，keeper 自动续 service_key，worker 自动续注册。
真正"一处秘密"。

## 检查健康状态

```bash
curl http://localhost:8080/healthz | jq
# {"ok":true,"has_oauth":false,"has_bridge":true,"last_oauth_seen_ms_ago":null}

curl http://localhost:8080/service-key | jq
# {"environment_id":"env_xxx","organization_id":"...","service_key":"sk-ant-oat01-..."}
```

## 多 worker 部署

```bash
# 多台机器，全连同一 keeper
KEEPER_URL=http://my-laptop.local:8080 ./run-bridge-via-keeper.sh
```

每台 worker 独立处理 session（claude.ai 后端按队列分发）。
