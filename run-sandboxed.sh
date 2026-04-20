#!/usr/bin/env bash
# Runs buddy-mcp as a sandboxed container. Wire this path into your MCP client.
#   - no network
#   - read-only rootfs, tmpfs /tmp
#   - non-root user inside container
#   - all Linux capabilities dropped, no privilege escalation
#   - bounded memory, pids, cpus (DoS ceiling)
#   - only ~/.buddy (or $BUDDY_DATA_DIR) is writable, for the SQLite file
#   - bind-mount paths are validated to be inside $HOME and non-symlinked,
#     so a rogue env var can't laundry writes into ~/.ssh or ~/.claude.json
set -euo pipefail

DATA_DIR="${BUDDY_DATA_DIR:-$HOME/.buddy}"
STATUS_FILE="${BUDDY_STATUS_FILE:-$HOME/.claude/buddy-status.json}"

mkdir -p "$DATA_DIR" "$(dirname "$STATUS_FILE")"
# Pre-create the status file so Docker bind-mounts it as a file, not a dir.
[ -e "$STATUS_FILE" ] || printf '{}' > "$STATUS_FILE"

# --- bind-mount path validation ---------------------------------------------
# Docker resolves -v symlinks on the host. If $BUDDY_STATUS_FILE points at (or
# a pre-planted symlink replaces the default with) ~/.claude.json or
# ~/.ssh/authorized_keys, the container's writes land there. Reject anything
# symlinked or resolving outside $HOME.
realpath_strict() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
  elif readlink -f / >/dev/null 2>&1; then
    readlink -f "$1"
  else
    echo "run-sandboxed: need python3 or GNU readlink to resolve paths" >&2
    exit 1
  fi
}

HOME_REAL="$(realpath_strict "$HOME")"
for p in "$DATA_DIR" "$STATUS_FILE"; do
  if [ -L "$p" ]; then
    echo "run-sandboxed: refusing symlinked bind-mount path: $p" >&2
    exit 1
  fi
  resolved="$(realpath_strict "$p")"
  case "$resolved/" in
    "$HOME_REAL"/*) ;;
    *)
      echo "run-sandboxed: refusing bind-mount outside \$HOME: $p -> $resolved" >&2
      exit 1
      ;;
  esac
done

exec docker run --rm -i \
  --network=none \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=16m \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --memory=256m \
  --memory-swap=256m \
  --pids-limit=128 \
  --cpus=1 \
  --ulimit nofile=256:256 \
  --init \
  -v "$DATA_DIR:/home/buddy/.buddy" \
  -v "$STATUS_FILE:/home/buddy/.claude/buddy-status.json" \
  buddy-mcp
