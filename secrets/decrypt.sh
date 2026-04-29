#!/bin/bash
# 解密本仓库 secrets/*.enc → 输出明文 token 到 stdout
# 用法:
#   KMS_KEY=<your-kms-api-key> ./secrets/decrypt.sh oauth
#   KMS_KEY=<your-kms-api-key> ./secrets/decrypt.sh ingress
set -e

: "${KMS_KEY:?需要设 KMS_KEY 环境变量（即 KMS API key，作 AES 解密口令）}"

DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
    oauth)
        IN="$DIR/oauth_token.enc"
        ;;
    ingress)
        IN="$DIR/session_ingress_token.enc"
        ;;
    *)
        echo "Usage: KMS_KEY=... $0 {oauth|ingress}" >&2
        exit 2
        ;;
esac

openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
    -pass "pass:$KMS_KEY" \
    -in "$IN"
