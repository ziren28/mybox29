# Build context = mybox29 repo root
# 用法:
#   docker build -f chat-api/Dockerfile -t 9527cheri/chat-api:latest .
#
# 运行:
#   docker run -d --name chat-api --restart unless-stopped \
#     -p 3000:3000 \
#     --env-file .env \
#     9527cheri/chat-api:latest

FROM oven/bun:1.3-alpine

WORKDIR /app
COPY chat-api.mjs /app/chat-api.mjs

ENV PORT=3000
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1:${PORT}/health || exit 1

CMD ["bun", "/app/chat-api.mjs"]
