#!/usr/bin/env bash
# Runs buddy-mcp as a sandboxed container. Wire this path into your MCP client.
#   - no network
#   - read-only rootfs, tmpfs /tmp
#   - non-root user inside container
#   - all Linux capabilities dropped, no privilege escalation
#   - only ~/.buddy (or $BUDDY_DATA_DIR) is writable, for the SQLite file
set -euo pipefail

DATA_DIR="${BUDDY_DATA_DIR:-$HOME/.buddy}"
STATUS_FILE="${BUDDY_STATUS_FILE:-$HOME/.claude/buddy-status.json}"

mkdir -p "$DATA_DIR" "$(dirname "$STATUS_FILE")"
# Pre-create the status file so Docker bind-mounts it as a file, not a dir.
[ -e "$STATUS_FILE" ] || printf '{}' > "$STATUS_FILE"

exec docker run --rm -i \
  --network=none \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=16m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  -v "$DATA_DIR:/home/buddy/.buddy" \
  -v "$STATUS_FILE:/home/buddy/.claude/buddy-status.json" \
  buddy-mcp
