#!/usr/bin/env node
// mybox29 host-keeper
// 用户提供 cookie → 跑 headless chromium 维持 claude.ai 登录态
// → 拦截浏览器 OAuth Bearer 请求自动捕获/刷新 access token
// → 暴露 HTTP API 供 worker 取最新 OAuth token / service_key
//
// 输入（环境变量）:
//   SESSION_KEY            浏览器 sessionKey cookie
//   CF_CLEARANCE           Cloudflare clearance cookie
//   ORG_ID                 organization UUID
//   PORT                   HTTP server 端口（默认 8080）
//
// HTTP endpoints:
//   GET /oauth             返回最新 OAuth Bearer token
//   GET /service-key       注册/续约 bridge environment 拿 service_key
//   POST /cookie           轮换 sessionKey/cf_clearance（用户重新刷新时）
//   GET /healthz           健康检查

import { chromium } from "/opt/node22/lib/node_modules/playwright/index.mjs";
import http from "node:http";

const SESSION_KEY = process.env.SESSION_KEY;
const CF_CLEARANCE = process.env.CF_CLEARANCE;
const ORG_ID = process.env.ORG_ID || "f7e0b9c2-5006-402e-87ca-e26147d218ad";
const PORT = +(process.env.PORT || 8080);

if (!SESSION_KEY || !CF_CLEARANCE) {
  console.error("SESSION_KEY and CF_CLEARANCE required");
  process.exit(1);
}

let oauthToken = null;
let lastSeen = 0;
let bridgeEnvId = null;
let bridgeServiceKey = null;

console.log(`[keeper] launching chromium...`);
const browser = await chromium.launch({
  headless: true,
  executablePath: "/opt/pw-browsers/chromium-1194/chrome-linux/chrome",
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
const ctx = await browser.newContext({
  userAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
  ignoreHTTPSErrors: true,
});

// 注入 cookie
await ctx.addCookies([
  { name: "sessionKey",   value: SESSION_KEY,  domain: ".claude.ai", path: "/", httpOnly: true, secure: true, sameSite: "Lax" },
  { name: "cf_clearance", value: CF_CLEARANCE, domain: ".claude.ai", path: "/", httpOnly: true, secure: true, sameSite: "None" },
  { name: "lastActiveOrg", value: ORG_ID,      domain: ".claude.ai", path: "/", secure: true, sameSite: "Lax" },
]);

const page = await ctx.newPage();

// 拦截所有 fetch/xhr，找带 Authorization: Bearer 的（这是 OAuth token）
page.on("request", (req) => {
  const auth = req.headers()["authorization"];
  if (auth && auth.startsWith("Bearer sk-ant-")) {
    const tok = auth.slice(7);
    if (tok !== oauthToken) {
      oauthToken = tok;
      lastSeen = Date.now();
      console.log(`[keeper] captured OAuth token (${tok.length}B) prefix=${tok.slice(0, 20)}…`);
    }
  }
});

console.log(`[keeper] navigating claude.ai/code...`);
await page.goto("https://claude.ai/code", { waitUntil: "domcontentloaded", timeout: 60000 });
console.log(`[keeper] page loaded, waiting for OAuth requests…`);

// 每 60 秒触发一次新请求保持 OAuth 活跃
setInterval(async () => {
  try {
    await page.evaluate(() => fetch("/api/account", { credentials: "include" }));
  } catch (e) { console.log(`[keeper] refresh fetch err: ${e.message}`); }
}, 60_000);

// ---- 注册/续约 bridge environment ----
// 浏览器 cookie 模式：在 page 内 fetch claude.ai 代理（同源/CF 已认证）
// OAuth Bearer 模式：直接调 api.anthropic.com（远端 VPS 用）
async function ensureBridge() {
  const body = {
    machine_name: process.env.MACHINE_NAME || "mybox29-keeper",
    directory: "/workspace", branch: "main", max_sessions: 1,
    metadata: { worker_type: "docker_container" },
    ...(bridgeEnvId ? { environment_id: bridgeEnvId } : {}),
  };

  // 优先：用浏览器 fetch（依赖 cookie）
  try {
    const j = await page.evaluate(async (b) => {
      const r = await fetch("https://claude.ai/v1/environments/bridge", {
        method: "POST", credentials: "include",
        headers: {
          "Content-Type": "application/json",
          "anthropic-version": "2023-06-01",
          "anthropic-beta": "ccr-byoc-2025-07-29,environments-2025-11-01",
          "anthropic-client-feature": "ccr",
          "anthropic-client-platform": "web_claude_ai",
          "x-organization-uuid": b.org,
          "x-environment-runner-version": "2.1.123",
        },
        body: JSON.stringify(b.body),
      });
      const text = await r.text();
      try { return { status: r.status, json: JSON.parse(text) }; }
      catch { return { status: r.status, body: text.slice(0, 300) }; }
    }, { org: ORG_ID, body });
    if (j.status === 200 && j.json?.environment_secret) {
      bridgeEnvId = j.json.environment_id;
      bridgeServiceKey = j.json.environment_secret;
      console.log(`[keeper] (cookie) bridge ${bridgeEnvId} service_key rotated (${bridgeServiceKey.length}B)`);
      return j.json;
    }
    console.log(`[keeper] cookie register failed status=${j.status}, falling back to OAuth`);
  } catch (e) {
    console.log(`[keeper] cookie register err: ${e.message}, trying OAuth`);
  }

  // 回退：OAuth Bearer 直接调 api.anthropic.com
  if (!oauthToken) throw new Error("Neither cookie nor OAuth available");
  const r = await fetch("https://api.anthropic.com/v1/environments/bridge", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${oauthToken}`,
      "Content-Type": "application/json",
      "anthropic-version": "2023-06-01",
      "anthropic-beta": "ccr-byoc-2025-07-29,environments-2025-11-01",
      "x-environment-runner-version": "2.1.123",
    },
    body: JSON.stringify(body),
  });
  if (!r.ok) throw new Error(`bridge register failed ${r.status}: ${await r.text()}`);
  const j = await r.json();
  bridgeEnvId = j.environment_id;
  bridgeServiceKey = j.environment_secret;
  console.log(`[keeper] (oauth) bridge ${bridgeEnvId} service_key rotated (${bridgeServiceKey.length}B)`);
  return j;
}

// 启动时立即注册一次
ensureBridge().catch(e => console.log(`[keeper] initial register failed (will retry): ${e.message}`));
// 每 30 分钟续约一次
setInterval(() => ensureBridge().catch(e => console.log(`[keeper] re-register failed: ${e.message}`)), 30 * 60_000);

// ---- HTTP server ----
http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  try {
    if (url.pathname === "/healthz") {
      res.end(JSON.stringify({
        ok: true, has_oauth: !!oauthToken, has_bridge: !!bridgeServiceKey,
        last_oauth_seen_ms_ago: lastSeen ? Date.now() - lastSeen : null,
      }));
    } else if (url.pathname === "/oauth") {
      if (!oauthToken) { res.writeHead(503); res.end(JSON.stringify({ error: "oauth not captured yet" })); return; }
      res.end(JSON.stringify({ token: oauthToken, captured_ms_ago: Date.now() - lastSeen }));
    } else if (url.pathname === "/service-key") {
      if (!bridgeServiceKey) await ensureBridge();
      res.end(JSON.stringify({
        environment_id: bridgeEnvId,
        organization_id: ORG_ID,
        service_key: bridgeServiceKey,
      }));
    } else if (url.pathname === "/rotate-service-key" && req.method === "POST") {
      await ensureBridge();
      res.end(JSON.stringify({
        environment_id: bridgeEnvId,
        organization_id: ORG_ID,
        service_key: bridgeServiceKey,
      }));
    } else {
      res.writeHead(404); res.end(JSON.stringify({ error: "not found" }));
    }
  } catch (e) {
    res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
  }
}).listen(PORT, () => console.log(`[keeper] HTTP listening on :${PORT}`));
