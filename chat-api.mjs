#!/usr/bin/env bun
// chat-api.mjs — HTTP API 封装, 把 chat-final.mjs 的能力暴露成 endpoint
//
// 启动:
//   bun chat-api.mjs              # 默认 :3000
//   PORT=8080 bun chat-api.mjs    # 自定义端口
//   bun chat-api.mjs &             # 后台运行
//
// 配套加载: 同目录 .env (可选默认值)
//
// 端点
//   GET  /health                  健康检查
//   POST /chat                    发消息, 不传 session_id 则自动建会话
//   POST /create-env              创建一个新的 anthropic_cloud environment (跑全新 cloud worker)
//   POST /refresh                 从 KMS 拉最新 token
//   POST /events                  低层: 直接转发 events POST/GET
//
// 全部 JSON in / JSON out.

import { readFileSync, existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

// ── 自动加载同目录 .env ──
const __dir = dirname(fileURLToPath(import.meta.url));
const envFile = join(__dir, ".env");
if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
        const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
        if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
}

const PORT          = +(process.env.PORT ?? 3000);
const DEFAULT_ORG   = process.env.ORG_ID    ?? "f7e0b9c2-5006-402e-87ca-e26147d218ad";
const DEFAULT_ENV   = process.env.BRIDGE_ENV_ID ?? "";
const DEFAULT_SK    = process.env.SESSION_KEY ?? "";
const DEFAULT_KMS   = process.env.KMS_URL ?? "https://kms-admin-4lo.pages.dev";

const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120";

// 完整 magic beta header 集 (来自浏览器抓包)
const MAGIC_BETA = [
    "ccr-byoc-2025-07-29",
    "claude-code-20250219",
    "interleaved-thinking-2025-05-14",
    "context-management-2025-06-27",
    "effort-2025-11-24",
].join(",");

const headersFor = (sk, org, opts = {}) => ({
    "anthropic-version":         "2023-06-01",
    "anthropic-beta":            opts.full_beta ? MAGIC_BETA : "ccr-byoc-2025-07-29",
    "anthropic-client-feature":  "ccr",
    "anthropic-client-platform": "web_claude_ai",
    "x-organization-uuid":       org,
    "user-agent":                UA,
    "Cookie":                    `sessionKey=${sk}`,
    ...(opts.client_sha && { "anthropic-client-sha": opts.client_sha }),
    ...(opts.direct_browser && { "anthropic-dangerous-direct-browser-access": "true" }),
});

const json = (obj, status = 200) =>
    new Response(JSON.stringify(obj, null, 2), {
        status,
        headers: { "content-type": "application/json; charset=utf-8" },
    });

// ─────────────────────────── /chat ───────────────────────────
async function handleChat(req) {
    let body;
    try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

    const sk     = body.cookie ?? body.session_key ?? DEFAULT_SK;
    const org    = body.org_id ?? DEFAULT_ORG;
    const envId  = body.environment_id ?? DEFAULT_ENV;
    const model  = body.model ?? "claude-sonnet-4-6";
    const think  = body.thinking !== false;
    const prompt = body.prompt ?? body.text ?? "";
    const TIMEOUT = +(body.timeout_ms ?? 120000);
    let sid      = body.session_id ?? null;

    // 高级 session_context 选项 (创建新会话时生效, 已有 session 忽略)
    const appendSystemPrompt = body.append_system_prompt ?? null;
    const allowedTools       = body.allowed_tools ?? null;  // 例: ["Bash","Read","Write","WebFetch","WebSearch"]
    const clientSha          = body.client_sha ?? null;
    const fullBeta           = body.full_beta !== false;    // 默认开

    if (!sk)     return json({ error: "cookie (sessionKey) required" }, 400);
    if (!prompt) return json({ error: "prompt required" }, 400);

    const HEADERS = headersFor(sk, org, { full_beta: fullBeta, client_sha: clientSha, direct_browser: true });

    // 1. 没传 session_id → 创建新会话 (含 append_system_prompt + allowed_tools)
    if (!sid) {
        const sessionContext = { model, sources: [], outcomes: [] };
        if (appendSystemPrompt) sessionContext.append_system_prompt = appendSystemPrompt;
        if (allowedTools)       sessionContext.allowed_tools         = allowedTools;

        const createBody = {
            title:           body.title ?? `API session ${new Date().toISOString().slice(0, 19)}`,
            session_context: sessionContext,
        };
        if (envId) createBody.environment_id = envId;

        const cr = await fetch("https://claude.ai/v1/sessions", {
            method:  "POST",
            headers: { ...HEADERS, "content-type": "application/json" },
            body:    JSON.stringify(createBody),
        });
        if (cr.status !== 200) {
            const detail = await cr.text();
            const cfChallenge = detail.includes("Just a moment") || detail.includes("cf-challenge");
            return json({
                error:    cfChallenge ? "Cloudflare challenged create-session request" : "create session failed",
                status:   cr.status,
                hint:     cfChallenge ? "deploy this API on a residential IP, or pre-create session_id in browser console and pass it in" : null,
                detail:   detail.slice(0, 500),
            }, 500);
        }
        sid = (await cr.json()).id;
    }

    // 2. POST user event
    const sinceTs = Date.now();
    const userMsg = {
        role: "user",
        content: [{ type: "text", text: prompt }],
        ...(think && { thinking: { type: "enabled", budget_tokens: 8192 } }),
    };
    const post = await fetch(`https://claude.ai/v1/sessions/${sid}/events`, {
        method:  "POST",
        headers: { ...HEADERS, "content-type": "application/json" },
        body:    JSON.stringify({
            events: [{
                type:               "user",
                uuid:               crypto.randomUUID(),
                session_id:         sid,
                parent_tool_use_id: null,
                message:            userMsg,
            }],
        }),
    });
    if (post.status !== 200) {
        return json({ session_id: sid, error: "post event failed", status: post.status, detail: await post.text() }, 500);
    }

    // 3. 轮询 GET events 直到 result
    const seen = new Set();
    let textBuf = "", thinkBuf = "", toolUses = [], gotResult = false;
    const start = Date.now();

    while (Date.now() - start < TIMEOUT) {
        const r = await fetch(`https://claude.ai/v1/sessions/${sid}/events?sort_order=asc&limit=200`, { headers: HEADERS });
        if (r.status !== 200) { await new Promise(r => setTimeout(r, 2000)); continue; }
        const j = await r.json();

        for (const e of (j.data ?? [])) {
            if (seen.has(e.uuid)) continue;
            seen.add(e.uuid);
            const ts = new Date(e.created_at).getTime();
            if (ts < sinceTs - 5000) continue;

            if (e.type === "assistant") {
                for (const c of (e.message?.content ?? [])) {
                    if (c.type === "thinking")      thinkBuf += (c.thinking ?? "") + "\n";
                    else if (c.type === "text")     textBuf  = c.text;
                    else if (c.type === "tool_use") toolUses.push({ id: c.id, name: c.name, input: c.input });
                }
            } else if (e.type === "result") {
                gotResult = true;
            }
        }
        if (gotResult) break;
        await new Promise(r => setTimeout(r, 1500));
    }

    return json({
        session_id:  sid,
        reply:       textBuf,
        thinking:    thinkBuf.trim() || null,
        tool_uses:   toolUses,
        duration_ms: Date.now() - start,
        completed:   gotResult,
        view_url:    `https://claude.ai/code/${sid}`,
    });
}

// ─────────────────────────── /refresh ───────────────────────────
async function handleRefresh(req) {
    let body;
    try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

    const kmsKey  = body.kms_api_key ?? process.env.KMS_API_KEY;
    const primary = body.secret_name ?? process.env.SECRET_NAME;
    const kmsUrl  = body.kms_url ?? DEFAULT_KMS;

    if (!kmsKey)  return json({ error: "kms_api_key required" }, 400);
    if (!primary) return json({ error: "secret_name required" }, 400);

    const loginResp = await fetch(`${kmsUrl}/api/login`, {
        method:  "POST",
        headers: { "content-type": "application/json" },
        body:    JSON.stringify({ password: kmsKey }),
    });
    if (loginResp.status !== 200) return json({ error: "kms login failed", status: loginResp.status }, 500);
    const { token: admin } = await loginResp.json();

    const sr = await fetch(`${kmsUrl}/api/secrets?primary=${encodeURIComponent(primary)}`, {
        headers: { Authorization: `Bearer ${admin}` },
    });
    const sj = await sr.json();
    const item = (sj.items ?? []).find(i => i.primary === primary);
    if (!item) return json({ error: "secret not found", primary }, 404);

    return json({
        primary:       item.primary,
        oauth_token:   item.key_data?.[".oauth_token"]            ?? null,
        ingress_token: item.key_data?.[".session_ingress_token"]  ?? null,
        updated_at:    item.updated_at,
        time:          item.key_data?.time ?? null,
    });
}

// ─────────────────────────── /create-env ───────────────────────────
async function handleCreateEnv(req) {
    let body;
    try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }

    const sk  = body.cookie ?? body.session_key ?? DEFAULT_SK;
    const org = body.org_id ?? DEFAULT_ORG;
    if (!sk) return json({ error: "cookie (sessionKey) required" }, 400);

    const HEADERS = headersFor(sk, org);
    const url = `https://claude.ai/v1/environment_providers/private/organizations/${org}/cloud/create`;

    const reqBody = {
        name:        body.name        ?? `mybox29-api-${Date.now()}`,
        kind:        body.kind        ?? "anthropic_cloud",
        description: body.description ?? "",
        config: {
            environment_type: "anthropic",
            cwd:              body.cwd ?? "/home/user",
            init_script:      body.init_script ?? null,
            environment:      body.environment ?? {},
            languages:        body.languages ?? [
                { name: "python", version: "3.11" },
                { name: "node",   version: "20"   },
            ],
            network_config:   body.network_config ?? { allowed_hosts: ["*"], allow_default_hosts: true },
        },
    };

    const r = await fetch(url, {
        method:  "POST",
        headers: { ...HEADERS, "content-type": "application/json" },
        body:    JSON.stringify(reqBody),
    });
    const text = await r.text();
    if (r.status !== 200) {
        const cfChallenge = text.includes("Just a moment") || text.includes("cf-challenge");
        return json({
            error:  cfChallenge ? "Cloudflare challenged create-env request" : "create env failed",
            status: r.status,
            hint:   cfChallenge ? "deploy this API on a residential IP, or pre-create env_id in browser console" : null,
            detail: text.slice(0, 500),
        }, 500);
    }

    let parsed; try { parsed = JSON.parse(text); } catch { parsed = { raw: text }; }
    return json({
        environment_id: parsed.environment_id ?? parsed.id ?? null,
        raw:            parsed,
    });
}

// ─────────────────────────── /events (低层透传) ───────────────────────────
async function handleEvents(req) {
    let body;
    try { body = await req.json(); } catch { return json({ error: "invalid JSON" }, 400); }
    const sk = body.cookie ?? body.session_key ?? DEFAULT_SK;
    const sid = body.session_id;
    const org = body.org_id ?? DEFAULT_ORG;
    if (!sk || !sid) return json({ error: "cookie + session_id required" }, 400);

    const HEADERS = headersFor(sk, org);

    if (body.action === "post") {
        const events = body.events ?? [];
        const r = await fetch(`https://claude.ai/v1/sessions/${sid}/events`, {
            method:  "POST",
            headers: { ...HEADERS, "content-type": "application/json" },
            body:    JSON.stringify({ events }),
        });
        return json({ status: r.status, body: await r.json().catch(() => null) });
    }
    // default: GET
    const r = await fetch(`https://claude.ai/v1/sessions/${sid}/events?sort_order=${body.sort_order ?? "asc"}&limit=${body.limit ?? 100}`, { headers: HEADERS });
    return json({ status: r.status, body: await r.json().catch(() => null) });
}

// ─────────────────────────── HTTP server ───────────────────────────
const server = Bun.serve({
    port: PORT,
    async fetch(req) {
        const url = new URL(req.url);

        if (req.method === "GET" && url.pathname === "/health") {
            return json({ ok: true, port: PORT, defaults: { org_id: DEFAULT_ORG, environment_id: DEFAULT_ENV || null, has_session_key: !!DEFAULT_SK } });
        }
        if (req.method === "GET" && url.pathname === "/") {
            return new Response(`mybox29 chat-api
endpoints:
  GET  /health
  POST /chat        {
    cookie?, session_id?, prompt, thinking?, environment_id?, model?,
    append_system_prompt?, allowed_tools?[], client_sha?, full_beta?,
    title?, timeout_ms?, org_id?
  }
  POST /create-env  {cookie?, name?, languages?[], cwd?, init_script?, environment?, network_config?}
  POST /refresh     {kms_api_key?, secret_name?, kms_url?}
  POST /events      {cookie?, session_id, action=post|get, events?[], sort_order?, limit?}

defaults loaded from .env (KMS_API_KEY, SECRET_NAME, SESSION_KEY, ORG_ID, BRIDGE_ENV_ID).
`, { headers: { "content-type": "text/plain; charset=utf-8" } });
        }
        if (req.method === "POST" && url.pathname === "/chat")        return handleChat(req);
        if (req.method === "POST" && url.pathname === "/create-env")  return handleCreateEnv(req);
        if (req.method === "POST" && url.pathname === "/refresh")     return handleRefresh(req);
        if (req.method === "POST" && url.pathname === "/events")      return handleEvents(req);

        return json({ error: "not found", method: req.method, path: url.pathname }, 404);
    },
});

console.log(`🚀 chat-api on http://localhost:${server.port}`);
console.log(`   GET  /health  POST /chat  POST /refresh  POST /events`);
console.log(`   defaults: org=${DEFAULT_ORG.slice(0, 8)}... session_key=${DEFAULT_SK ? `(${DEFAULT_SK.length}B from .env)` : "(none)"}`);
