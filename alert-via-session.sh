#!/bin/bash
# 在不依赖外部 webhook 的情况下，直接把告警注入到用户当前 claude.ai session。
# 用户在网页对话框就会看到一条提醒。
#
# 用法:
#   SESSION_KEY=<sk-ant-sid02-...> CF_CLEARANCE=<cookie> SESSION_ID=session_xxx \
#     ./alert-via-session.sh "⚠️ token expired, refresh: https://..."

set -euo pipefail
: "${SESSION_KEY:?}"
: "${CF_CLEARANCE:?}"
: "${SESSION_ID:?}"
: "${1:?需要消息内容作参数}"

ORG="${ORG:-f7e0b9c2-5006-402e-87ca-e26147d218ad}"
MSG="$1"

curl -fsS -X POST "https://claude.ai/v1/sessions/$SESSION_ID/events" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: ccr-byoc-2025-07-29" \
  -H "anthropic-client-feature: ccr" \
  -H "anthropic-client-platform: web_claude_ai" \
  -H "x-organization-uuid: $ORG" \
  -H "user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
  -H "referer: https://claude.ai/code/$SESSION_ID" \
  -b "sessionKey=$SESSION_KEY; cf_clearance=$CF_CLEARANCE; lastActiveOrg=$ORG" \
  --data-raw "{\"events\":[{\"type\":\"control_request\",\"request_id\":\"watchdog-$(date +%s)\",\"request\":{\"subtype\":\"send_user_message\",\"content\":$(jq -Rs <<<"$MSG")}}]}" \
  >/dev/null && echo "✅ alert injected into session $SESSION_ID"
