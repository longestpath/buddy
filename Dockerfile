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
#
# Base image is pinned by digest — `docker pull node:22-alpine && docker inspect \
# --format='{{index .RepoDigests 0}}' node:22-alpine` to refresh. Rotate on
# upstream CVE or quarterly.


# ---- statusline-builder: npm ci WITHOUT transitive postinstall scripts ----
#
# This stage produces the dist/ that install-sandboxed.sh docker-cp's onto the
# host, where it runs unsandboxed on every Claude Code statusline tick. If any
# transitive npm dep is compromised, its postinstall (with full network during
# build) could tamper with dist/ before extraction. Scripts-off means only
# tsc (from our own source) contributes to the extracted output. The statusline
# has no native deps, so this compiles cleanly without node-gyp.
FROM node:22-alpine@sha256:8ea2348b068a9544dae7317b4f3aafcdc032df1647bb7d768a05a5cad1a7683f AS statusline-builder
WORKDIR /src

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY tsconfig.json ./
COPY src ./src
RUN npm run build


# ---- server-builder: full install with native toolchain ----
#
# Scripts enabled because better-sqlite3 needs node-gyp. Output stays inside
# the image (container-only) — nothing from this stage is docker-cp'd to the
# host.
FROM node:22-alpine@sha256:8ea2348b068a9544dae7317b4f3aafcdc032df1647bb7d768a05a5cad1a7683f AS server-builder
WORKDIR /src

RUN apk add --no-cache python3 make g++

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build \
 && npm prune --omit=dev


# ---- runtime ----
FROM node:22-alpine@sha256:8ea2348b068a9544dae7317b4f3aafcdc032df1647bb7d768a05a5cad1a7683f AS runtime

RUN addgroup -S buddy \
 && adduser -S -G buddy -h /home/buddy buddy \
 && install -d -o buddy -g buddy /home/buddy/.buddy

WORKDIR /app
COPY --from=server-builder --chown=buddy:buddy /src/node_modules ./node_modules
COPY --from=server-builder --chown=buddy:buddy /src/dist         ./dist
COPY --from=server-builder --chown=buddy:buddy /src/package.json ./package.json

USER buddy
ENV HOME=/home/buddy \
    NODE_ENV=production

ENTRYPOINT ["node", "/app/dist/server/index.js"]
