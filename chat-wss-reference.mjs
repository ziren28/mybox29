// 完整 demo：从外部用 sessionKey 给 cse_01V82Z8wpDKai5GCs2hHxbNn 注入一条 user message，
// 通过 WSS 接收容器内 claude 的流式回复（含 thinking）。

const ORG_ID = "f7e0b9c2-5006-402e-87ca-e26147d218ad";
const SESSION_KEY = "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";
const CF_CLEARANCE = "DglscuL6VOitQxQr_ohMvqzMJppDxO0OPFNtzphCCyA-1777451393-1.2.1.1-kfJmZfVcYbZNJtRlMTCvOyfmMda64sJO.1cShMyjtfvbKj.H6JfwnPdmnTXbbcWaKlbT6Cd.GLbba4vCB24o3KC239PEqNYdmxj74TgkRDcv1VTtqMz7.cjEHpzM.R031AHZHgKwpdCZfEQr7cSWeb.PrrQ1MsLMlW5XD5L_M2rUnz.6FUbxaAi.xKGpLwDLoCblAKHzBZ36Px6iVWauPk50TrKviZr5UZo9ZwcVHdve2ZIJ5Kcp.91zyoGJwGRyVseRXzli6yfJJkk0yG8wEJsSnCdY.dpwATVJw_vuBOj.21DOQ65CRWvF66JBYUwosrhNnHUBKrTXn5EsqmCDLg";
const COOKIE = `sessionKey=${SESSION_KEY}; cf_clearance=${CF_CLEARANCE}; lastActiveOrg=${ORG_ID}`;

// 目标：mybox29 自建的 bridge session（worker 在容器里）
const SESSION_ID = "cse_01V82Z8wpDKai5GCs2hHxbNn";
const PROMPT = "你好，从外部 WSS 注入的测试消息。请用一句话回复你的运行环境是什么（重点：是不是 mybox29:1.3.1 容器）？";

const MAGIC_BETA = "ccr-byoc-2025-07-29";

const wsUrl = `wss://claude.ai/v1/sessions/ws/${SESSION_ID}/subscribe?organization_uuid=${ORG_ID}`;
console.log(`⏳ 连接 WSS: ${wsUrl}`);

const ws = new WebSocket(wsUrl, {
    headers: { "Cookie": COOKIE, "Origin": "https://claude.ai" }
});

let fullReply = "", thinkPrinted = false;
let assistantTextStarted = false;
const startedAt = Date.now();

ws.onopen = async () => {
    console.log("🟢 WSS connected\n");

    console.log("📤 POST user message (thinking enabled)…");
    try {
        const r = await fetch(`https://claude.ai/v1/sessions/${SESSION_ID}/events`, {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Cookie": COOKIE,
                "Origin": "https://claude.ai",
                "Referer": `https://claude.ai/code/${SESSION_ID}`,
                "x-organization-uuid": ORG_ID,
                "anthropic-client-platform": "web_claude_ai",
                "anthropic-version": "2023-06-01",
                "anthropic-beta": MAGIC_BETA,
                "anthropic-client-feature": "ccr",
                "user-agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
            },
            body: JSON.stringify({
                events: [{
                    type: "user",
                    uuid: crypto.randomUUID(),
                    session_id: SESSION_ID,
                    parent_tool_use_id: null,
                    message: {
                        role: "user",
                        content: [{ type: "text", text: PROMPT }],
                        thinking: { type: "enabled", budget_tokens: 4096 }
                    }
                }]
            })
        });
        console.log(`📡 status=${r.status}`);
        if (r.status >= 400) console.log(await r.text());
    } catch (e) {
        console.error("❌ POST failed:", e.message);
        ws.close();
    }
};

ws.onmessage = (event) => {
    try {
        const data = JSON.parse(event.data);
        if (data.type === "assistant" || data.message) {
            const items = data.message?.content || [];
            for (const item of items) {
                if (item.type === "thinking") {
                    if (!thinkPrinted) { process.stdout.write("\n🧠 [thinking] "); thinkPrinted = true; }
                    process.stdout.write((item.thinking || item.text || "").slice(thinkPrinted ? -50 : 0));
                } else if (item.type === "text") {
                    if (!assistantTextStarted) { process.stdout.write("\n\n💬 [reply]\n"); assistantTextStarted = true; }
                    const newText = item.text.slice(fullReply.length);
                    if (newText) { process.stdout.write(newText); fullReply = item.text; }
                }
            }
        } else if (data.type === "result") {
            console.log(`\n\n🏁 result received after ${(Date.now() - startedAt)/1000}s`);
            ws.close();
        }
    } catch (e) {}
};

ws.onerror = (e) => console.error("⚠️ WSS error:", e.message || e);
ws.onclose = () => { console.log("🔴 WSS closed"); process.exit(0); };

setTimeout(() => { console.log("\n⏰ timeout 45s"); ws.close(); }, 45000);
