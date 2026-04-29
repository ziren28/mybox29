#!/bin/bash
# mybox29 一键启动脚本：解密本仓库 secrets/ 凭证并 docker run 容器
# 用法:
#   KMS_KEY=<your-kms-api-key> ./run.sh             # 默认 1.1.0 + bash
#   KMS_KEY=<your-kms-api-key> ./run.sh 1.1.0       # 指定 tag
#   KMS_KEY=<your-kms-api-key> ./run.sh 1.1.0 claude --print "hi"
set -e

: "${KMS_KEY:?需要设 KMS_KEY 环境变量（即 KMS API key）}"

DIR="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-1.1.0}"
shift 2>/dev/null || true

OAUTH=$("$DIR/secrets/decrypt.sh" oauth)
INGRESS=$("$DIR/secrets/decrypt.sh" ingress)

exec docker run --rm -it \
    -e CLAUDE_OAUTH_TOKEN="$OAUTH" \
    -e CLAUDE_SESSION_INGRESS_TOKEN="$INGRESS" \
    -v "$PWD:/workspace" \
    "9527cheri/mybox29:$TAG" "$@"
