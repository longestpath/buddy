#!/usr/bin/env bash
# Buddy MCP — sandboxed installer (strictly narrower than upstream install.sh).
#
# Does:
#   1. Build two Docker targets (skip if already present):
#        - buddy-mcp-statusline (scripts-off, produces trustworthy dist/)
#        - buddy-mcp            (runtime, scripts-on for native modules)
#   2. Extract dist/ from the statusline stage into the repo. The host-side
#      statusline wrapper is run unsandboxed by Claude Code every ~2s, so
#      its source must NOT include anything touched by transitive npm
#      postinstall scripts. That's why extraction comes from the
#      scripts-off stage, not from the runtime image.
#   3. Patch ~/.claude/settings.json to point statusLine at the wrapper
#      (idempotent; backs up prior file on replacement; refuses to clobber
#      malformed JSON).
#   4. With --register: run `claude mcp add buddy -s user -- run-sandboxed.sh`,
#      and (unless --no-inject-prompt) append the buddy-companion sentinel
#      block to ~/.claude/CLAUDE.md so agents know to call buddy_observe.
#      Without the prompt, agents see the tools but never use them.
#
# Does NOT touch:
#   - ~/.claude.json (unless --register, via the official claude CLI)
#   - ~/.cursor/rules, ~/.codex, ~/.gemini, ~/.copilot  (no prompt injection)
#   - settings.json PostToolUse hooks (no post-Bash hook)
#   - any network at server runtime (the container runs offline)

set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")" && pwd)}"
IMAGE="${IMAGE:-buddy-mcp}"
STATUSLINE_IMAGE="${STATUSLINE_IMAGE:-buddy-mcp-statusline}"
SETTINGS="$HOME/.claude/settings.json"
REGISTER=0
SKIP_BUILD=0
INJECT_PROMPT=1

for arg in "$@"; do
  case "$arg" in
    --register)         REGISTER=1 ;;
    --skip-build)       SKIP_BUILD=1 ;;
    --no-inject-prompt) INJECT_PROMPT=0 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      echo
      echo "Usage: install-sandboxed.sh [--register] [--skip-build] [--no-inject-prompt]"
      exit 0
      ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
need docker
need node

# 1. Build images if missing
if [ "$SKIP_BUILD" -eq 0 ]; then
  if ! docker image inspect "$STATUSLINE_IMAGE" >/dev/null 2>&1; then
    echo "  building $STATUSLINE_IMAGE (scripts-off, for host-side statusline)..."
    docker build --target statusline-builder -t "$STATUSLINE_IMAGE" "$REPO"
  else
    echo "  image $STATUSLINE_IMAGE: present"
  fi
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "  building $IMAGE (runtime)..."
    docker build -t "$IMAGE" "$REPO"
  else
    echo "  image $IMAGE: present"
  fi
else
  echo "  skipping docker build (--skip-build)"
fi

# 2. Extract dist/ from the scripts-off statusline image.
#    Anything copied here runs on the host every ~2s under Claude Code's
#    statusline refresh — so the provenance of this dist/ is load-bearing.
echo "  extracting dist/ from $STATUSLINE_IMAGE..."
CID=$(docker create "$STATUSLINE_IMAGE")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
rm -rf "$REPO/dist"
docker cp "$CID:/src/dist" "$REPO/dist" >/dev/null
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
const raw = fs.readFileSync(path, 'utf-8');
let cfg;
try {
  cfg = JSON.parse(raw);
} catch (e) {
  // Refuse to clobber. Emitting "invalid" tells the shell caller to stop.
  process.stderr.write(`settings.json is not valid JSON: ${e.message}\n`);
  process.stdout.write('invalid');
  process.exit(0);
}
const prev = cfg.statusLine;
const same = prev && JSON.stringify(prev) === JSON.stringify(desired);
if (same) { process.stdout.write('noop'); process.exit(0); }
cfg.statusLine = desired;
fs.writeFileSync(path, JSON.stringify(cfg, null, 2));
process.stdout.write(prev ? 'replaced' : 'added');
EOJS
)

case "$RESULT" in
  invalid)
    # We haven't modified the target — discard the backup we took preemptively.
    rm -f "$BACKUP"
    echo "  settings.json is malformed. Fix or delete it, then re-run." >&2
    exit 3
    ;;
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

# Prune old settings.json backups — keep the most recent 5.
# Using a glob-safe listing that tolerates no matches.
backups=("$SETTINGS".bak.*)
if [ -e "${backups[0]}" ]; then
  # shellcheck disable=SC2012 # ls -t is fine here; filenames are timestamped
  ls -1t "$SETTINGS".bak.* 2>/dev/null | tail -n +6 | while IFS= read -r old; do
    rm -f -- "$old"
  done
fi

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

# 5. Inject buddy instructions into ~/.claude/CLAUDE.md.
#    Without this, agents see buddy_* tools but have no instruction telling
#    them to call buddy_observe after work — so they don't, and the buddy
#    stays silent. Skipped under --no-inject-prompt; idempotent via the
#    buddy-companion sentinel marker.
if [ "$REGISTER" -eq 1 ] && [ "$INJECT_PROMPT" -eq 1 ]; then
  CLAUDE_MD="$HOME/.claude/CLAUDE.md"
  mkdir -p "$(dirname "$CLAUDE_MD")"
  if [ -f "$CLAUDE_MD" ] && grep -q "buddy-companion" "$CLAUDE_MD" 2>/dev/null; then
    echo "  CLAUDE.md prompt: already injected"
  else
    cat >> "$CLAUDE_MD" <<'EOF'

<!-- buddy-companion -->
## Buddy Companion

You have a coding companion available via the buddy MCP server.

**After completing any coding task** (writing code, fixing bugs, refactoring, deploying, running tests), **automatically call `buddy_observe`** with a 1-sentence summary of what you did. This gives your companion XP and triggers a personality-flavored reaction. Do this every time — the user expects it.

At the start of each conversation, call `buddy_status` to check on your buddy.

If the user addresses the buddy by name, respond briefly in character before your normal response.

After calling buddy_observe, relay the buddy's reaction to the user. The first text content is an ASCII speech bubble — include it verbatim.
<!-- /buddy-companion -->
EOF
    echo "  CLAUDE.md prompt: injected"
  fi
fi

echo
echo "done. restart Claude Code to pick up the statusline."
