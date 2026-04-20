# syntax=docker/dockerfile:1.6
#
# Buddy MCP — network-isolated sandbox image.
#
# Build:  docker build -t buddy-mcp /opt/code/buddy
# Run:    launched by the MCP client; see run-sandboxed.sh for the argv.
#
# Security posture (enforced at runtime by the invoker, not the image):
#   --network=none                no outbound network
#   --read-only                   immutable rootfs
#   --cap-drop=ALL                no Linux capabilities
#   --security-opt=no-new-privileges
#   USER buddy                    non-root uid inside container
#   tmpfs /tmp                    writable scratch, wiped each run
#   bind mount ~/.buddy            only path the server writes to

FROM node:22-alpine AS builder
WORKDIR /src

# Native-module toolchain for better-sqlite3. Discarded with the stage.
RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts=false

COPY tsconfig.json ./
COPY src ./src
RUN npm run build \
 && npm prune --omit=dev


FROM node:22-alpine AS runtime

RUN addgroup -S buddy \
 && adduser -S -G buddy -h /home/buddy buddy \
 && install -d -o buddy -g buddy /home/buddy/.buddy

WORKDIR /app
COPY --from=builder --chown=buddy:buddy /src/node_modules ./node_modules
COPY --from=builder --chown=buddy:buddy /src/dist         ./dist
COPY --from=builder --chown=buddy:buddy /src/package.json ./package.json

USER buddy
ENV HOME=/home/buddy \
    NODE_ENV=production

ENTRYPOINT ["node", "/app/dist/server/index.js"]
