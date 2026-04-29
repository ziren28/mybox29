#!/usr/bin/env bun
// mybox29-chat: 直接跟你自建的 mybox29 worker 容器对话
//
// 不需要打开 claude.ai 网页 UI，纯 CLI 走 BYOC 协议:
//   1. POST /v1/sessions/{id}/events  type:user  → 写消息进 session
//   2. GET  /v1/sessions/{id}/events  轮询      → 拉 assistant 回复
//
// 用法 (假设凭证存在 KMS):
//   bun chat.mjs "你好，请简述运行环境"
//
// 环境变量:
//   SESSION_KEY      sessionKey cookie (claude.ai 浏览器登录态)
//   CF_CLEARANCE     cf_clearance cookie
//   ORG_ID           organization UUID
//   SESSION_ID       session_xxx (mybox29 worker 处理的 session)

const SK    = process.env.SESSION_KEY  ?? "";
const CF    = process.env.CF_CLEARANCE ?? "";
const ORG   = process.env.ORG_ID       ?? "f7e0b9c2-5006-402e-87ca-e26147d218ad";
const SID   = process.env.SESSION_ID   ?? "session_01V82Z8wpDKai5GCs2hHxbNn";
const PROMPT = process.argv[2] || "Hello, are you there?";

if (!SK) { console.error("SESSION_KEY required"); process.exit(1); }

const COOKIE = `sessionKey=${SK}; cf_clearance=${CF}; lastActiveOrg=${ORG}`;
const HEADERS = {
  "anthropic-version": "2023-06-01",
  "anthropic-beta": "ccr-byoc-2025-07-29",
  "anthropic-client-feature": "ccr",
  "anthropic-client-platform": "web_claude_ai",
  "x-organization-uuid": ORG,
  "user-agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36",
  "referer": `https://claude.ai/code/${SID}`,
  "origin": "https://claude.ai",
  "Cookie": COOKIE,
};

// 1. 推消息
const sinceTs = Date.now();
console.log(`📤 POST type:user → ${SID}`);
const post = await fetch(`https://claude.ai/v1/sessions/${SID}/events`, {
  method: "POST",
  headers: { ...HEADERS, "content-type": "application/json" },
  body: JSON.stringify({
    events: [{
      type: "user",
      uuid: crypto.randomUUID(),
      session_id: SID,
      parent_tool_use_id: null,
      message: {
        role: "user",
        content: [{ type: "text", text: PROMPT }],
        thinking: { type: "enabled", budget_tokens: 4096 },
      },
    }],
  }),
});
console.log(`   status=${post.status}`);
if (post.status !== 200) { console.log(await post.text()); process.exit(1); }

// 2. 轮询事件流，直到 assistant 完成
const seen = new Set();
let lastCursor;
const start = Date.now();
console.log("📥 polling events…\n");
while (Date.now() - start < 120000) {
  const params = new URLSearchParams({ sort_order: "asc", limit: "50" });
  if (lastCursor) params.set("cursor", lastCursor);
  const r = await fetch(`https://claude.ai/v1/sessions/${SID}/events?` + params, { headers: HEADERS });
  if (r.status !== 200) { await new Promise(r=>setTimeout(r,2000)); continue; }
  const j = await r.json();
  for (const e of (j.data ?? [])) {
    if (seen.has(e.uuid)) continue;
    seen.add(e.uuid);
    if (e.timestamp_ms < sinceTs - 5000) continue;
    if (e.type === "assistant") {
      const msg = e.payload?.message ?? e.payload ?? {};
      for (const c of (msg.content ?? [])) {
        if (c.type === "thinking") process.stdout.write(`\n🧠 ${(c.thinking||c.text||"").slice(0,500)}\n`);
        else if (c.type === "text") process.stdout.write(c.text);
      }
    } else if (e.type === "result") {
      console.log("\n\n🏁 done");
      process.exit(0);
    }
    lastCursor = e.sequence_num ?? lastCursor;
  }
  await new Promise(r=>setTimeout(r,1500));
}
console.log("\n⏰ timeout");
