#!/usr/bin/env bun
// chat-final.mjs — 纯 CLI 跟 mybox29 worker / 任意 claude.ai session 对话
//
// 实测 (2026-04-29): claude.ai BYOC events API 仅需 sessionKey 一个 cookie,
// 不需要 cf_clearance / __cf_bm. 因此本脚本零浏览器依赖.
//
// 用法 (推荐): 把变量写进 .env 后直接跑
//   bun chat-final.mjs "你好, 请简述运行环境"
//
// 或临时 inline:
//   SESSION_KEY=... SESSION_ID=... bun chat-final.mjs "..."

// 自动加载同目录 .env
import { readFileSync, existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
const __dir = dirname(fileURLToPath(import.meta.url));
const envFile = join(__dir, ".env");
if (existsSync(envFile)) {
    for (const line of readFileSync(envFile, "utf8").split("\n")) {
        const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
        if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
}

const SK      = process.env.SESSION_KEY ?? "";
const SID     = process.env.SESSION_ID  ?? "";
const ORG     = process.env.ORG_ID      ?? "f7e0b9c2-5006-402e-87ca-e26147d218ad";
const THINK   = process.env.THINKING !== "0";
const TIMEOUT = +(process.env.TIMEOUT_MS ?? 120000);
const PROMPT  = process.argv.slice(2).join(" ") || "Hello, are you there?";

if (!SK)  { console.error("SESSION_KEY required"); process.exit(1); }
if (!SID) { console.error("SESSION_ID required"); process.exit(1); }

const HEADERS = {
    "anthropic-version":         "2023-06-01",
    "anthropic-beta":            "ccr-byoc-2025-07-29",
    "anthropic-client-feature":  "ccr",
    "anthropic-client-platform": "web_claude_ai",
    "x-organization-uuid":       ORG,
    "user-agent":                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120",
    "Cookie":                    `sessionKey=${SK}`,
};

// 1. POST user event
const sinceTs = Date.now();
console.log(`📤 POST user event → ${SID}`);
const userMsg = {
    role: "user",
    content: [{ type: "text", text: PROMPT }],
    ...(THINK && { thinking: { type: "enabled", budget_tokens: 8192 } }),
};
const post = await fetch(`https://claude.ai/v1/sessions/${SID}/events`, {
    method:  "POST",
    headers: { ...HEADERS, "content-type": "application/json" },
    body:    JSON.stringify({
        events: [{
            type:               "user",
            uuid:               crypto.randomUUID(),
            session_id:         SID,
            parent_tool_use_id: null,
            message:            userMsg,
        }],
    }),
});
console.log(`   status=${post.status}`);
if (post.status !== 200) { console.log(await post.text()); process.exit(1); }

// 2. 轮询 GET events 拉 assistant 回复
const seen = new Set();
let textBuf = "", thinkPrinted = false, gotResult = false;
const start = Date.now();
console.log("📥 polling events...\n");

while (Date.now() - start < TIMEOUT) {
    const r = await fetch(
        `https://claude.ai/v1/sessions/${SID}/events?sort_order=asc&limit=100`,
        { headers: HEADERS },
    );
    if (r.status !== 200) { await new Promise(r => setTimeout(r, 2000)); continue; }
    const j = await r.json();

    for (const e of (j.data ?? [])) {
        if (seen.has(e.uuid)) continue;
        seen.add(e.uuid);
        const ts = new Date(e.created_at).getTime();
        if (ts < sinceTs - 5000) continue;

        if (e.type === "assistant") {
            for (const c of (e.message?.content ?? [])) {
                if (c.type === "thinking") {
                    if (!thinkPrinted) { process.stdout.write(`\n🧠 `); thinkPrinted = true; }
                    process.stdout.write((c.thinking ?? "").slice(0, 500) + "\n");
                } else if (c.type === "text") {
                    const newText = c.text.slice(textBuf.length);
                    if (newText) { process.stdout.write(newText); textBuf = c.text; }
                } else if (c.type === "tool_use") {
                    process.stdout.write(`\n🔧 ${c.name}: ${c.input?.description ?? c.input?.command?.slice(0,80) ?? ""}\n`);
                }
            }
        } else if (e.type === "user" && e.message?.content?.[0]?.type === "tool_result") {
            const r = e.message.content[0];
            const out = (typeof r.content === "string" ? r.content : "").slice(0, 400);
            if (out) process.stdout.write(`\n📋 ${out}${out.length >= 400 ? "..." : ""}\n`);
        } else if (e.type === "result") {
            console.log(`\n\n🏁 done in ${((Date.now()-start)/1000).toFixed(1)}s`);
            gotResult = true;
        }
    }
    if (gotResult) break;
    await new Promise(r => setTimeout(r, 1500));
}

if (!gotResult) console.log(`\n⏰ timeout after ${TIMEOUT/1000}s`);
process.exit(0);
