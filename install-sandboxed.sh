#!/usr/bin/env bash
# Buddy MCP — sandboxed installer (strictly narrower than upstream install.sh).
#
# Does:
#   1. Build the Docker image (skip if already present).
#   2. Extract dist/ from the image into the repo for the host-side statusline wrapper.
#   3. Patch ~/.claude/settings.json to point statusLine at the wrapper (backup saved).
#   4. With --register: run `claude mcp add buddy -s user -- run-sandboxed.sh`.
#
# Does NOT touch:
#   - ~/.claude.json (unless --register, via the official claude CLI)
#   - ~/.claude/CLAUDE.md, ~/.cursor/rules, ~/.codex, ~/.gemini, ~/.copilot  (no prompt injection)
#   - settings.json PostToolUse hooks (no post-Bash hook)
#   - any network (the container runs offline)

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")" && pwd)}"
IMAGE="${IMAGE:-buddy-mcp}"
SETTINGS="$HOME/.claude/settings.json"
REGISTER=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --register)   REGISTER=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help)
      sed -n '2,17p' "$0"
      echo
      echo "Usage: install-sandboxed.sh [--register] [--skip-build]"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need docker
need node

# 1. Build image if missing
if [ "$SKIP_BUILD" -eq 0 ] && ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  building $IMAGE..."
  docker build -t "$IMAGE" "$REPO"
else
  echo "  image $IMAGE: present"
fi

# 2. Extract dist/ from image into the repo
echo "  extracting dist/ from $IMAGE..."
CID=$(docker create "$IMAGE")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
rm -rf "$REPO/dist"
docker cp "$CID:/app/dist" "$REPO/dist" >/dev/null
docker rm "$CID" >/dev/null
trap - EXIT

STATUSLINE_CMD="node $REPO/dist/statusline-wrapper.js"
DESIRED_JSON="$(printf '{"type":"command","command":%s,"padding":1,"refreshInterval":2}' \
  "$(node -e 'console.log(JSON.stringify(process.argv[1]))' "$STATUSLINE_CMD")")"

# 3. Patch ~/.claude/settings.json — back up first, then edit.
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || printf '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"

RESULT=$(SETTINGS_FILE="$SETTINGS" DESIRED_JSON="$DESIRED_JSON" node <<'EOJS'
const fs = require('fs');
const path = process.env.SETTINGS_FILE;
const desired = JSON.parse(process.env.DESIRED_JSON);
let cfg;
try { cfg = JSON.parse(fs.readFileSync(path, 'utf-8')); } catch { cfg = {}; }
const prev = cfg.statusLine;
const same = prev && JSON.stringify(prev) === JSON.stringify(desired);
if (same) { process.stdout.write('noop'); process.exit(0); }
cfg.statusLine = desired;
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
process.stdout.write(prev ? 'replaced' : 'added');
EOJS
)

case "$RESULT" in
  noop)
    rm -f "$BACKUP"
    echo "  statusLine: already correct (no changes, backup discarded)"
    ;;
  added)
    rm -f "$BACKUP"    # no prior statusLine to preserve; original file had none
    echo "  statusLine: added"
    ;;
  replaced)
    echo "  statusLine: replaced (previous contents backed up to $BACKUP)"
    ;;
esac

# 4. Optional MCP registration
if [ "$REGISTER" -eq 1 ]; then
  if ! command -v claude >/dev/null; then
    echo "  claude CLI not found; skipping MCP registration"
  elif claude mcp get buddy >/dev/null 2>&1; then
    echo "  MCP buddy: already registered"
  else
    claude mcp add buddy -s user -- "$REPO/run-sandboxed.sh" >/dev/null
    echo "  MCP buddy: registered"
  fi
fi

echo
echo "done. restart Claude Code to pick up the statusline."
