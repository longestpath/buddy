#!/usr/bin/env bash
# buddy-pane.sh — dedicate a terminal pane to your buddy.
#
# Runs the statusline-wrapper on a loop against ~/.claude/buddy-status.json,
# which every `buddy_*` MCP tool call writes to. No statusline required.
#
# Usage:
#   ./buddy-pane.sh              # default 2s refresh, right-aligned
#   ./buddy-pane.sh 1            # 1s refresh
#   BUDDY_PANE_TOP=4 ./buddy-pane.sh   # 4 blank rows above the sprite
#   BUDDY_RIGHT_ALIGN=0 ./buddy-pane.sh  # disable right-align (default: on)
#   BUDDY_COMPACT=1 ./buddy-pane.sh      # drop species/stars/ambient (for ultra-narrow panes)
#   BUDDY_PANE_WIDTH=45 ./buddy-pane.sh   # override when tput misreports pane width
#   BUDDY_PANE_CLEAR_EVERY=30 ./buddy-pane.sh  # full-clear every N ticks (0 disables)
#   BUDDY_ENABLE_HUD=1 ./buddy-pane.sh

set -u

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$REPO/dist/statusline-wrapper.js"
INTERVAL="${1:-2}"
TOP_PADDING="${BUDDY_PANE_TOP:-2}"

case "$TOP_PADDING" in
  ''|*[!0-9]*) echo "buddy-pane: BUDDY_PANE_TOP must be a non-negative integer" >&2; exit 1 ;;
esac

# Right-align the buddy block to the pane's right edge by default, so the
# sprite doesn't visually jump sideways when a speech bubble appears/expires.
# Set BUDDY_RIGHT_ALIGN=0 to revert to the default left margin.
: "${BUDDY_RIGHT_ALIGN:=1}"
export BUDDY_RIGHT_ALIGN

# Compact mode: drops species annotation, rarity stars, ambient activity text,
# and reaction-text trailer so the info fits in very narrow panes. With the
# terminal-width-aware indent cap and BUDDY_PANE_WIDTH override, full info
# usually fits; enable compact explicitly for panes narrower than ~40 cols.
: "${BUDDY_COMPACT:=0}"
export BUDDY_COMPACT

# Periodic full-clear interval, in ticks. Catches cumulative debris from pane
# resize (laptop docking) or wide-character overdraw that the per-line \e[K
# misses. 30 ticks * 2s = ~once a minute. Set to 0 to disable.
: "${BUDDY_PANE_CLEAR_EVERY:=30}"
case "$BUDDY_PANE_CLEAR_EVERY" in
  ''|*[!0-9]*) echo "buddy-pane: BUDDY_PANE_CLEAR_EVERY must be a non-negative integer" >&2; exit 1 ;;
esac

if [ ! -f "$WRAPPER" ]; then
  echo "buddy-pane: wrapper not found at $WRAPPER" >&2
  echo "  run: (cd \"$REPO\" && npm run build)" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "buddy-pane: node not on PATH" >&2
  exit 1
fi

# Hide the cursor, clear the screen, restore on exit (any signal).
cleanup() {
  printf '\033[?25h\033[0m\n'
  exit 0
}
trap cleanup INT TERM HUP EXIT

printf '\033[?25l'
tput clear 2>/dev/null || clear

TICK=0
while :; do
  # Re-measure each tick so the wrapper adapts if the pane is resized.
  # When stdout is piped (through sed below), node's process.stdout.columns
  # is unset, so we pass the width via $COLUMNS.
  # Width resolution order: explicit override > stty size > tput cols > 80.
  # tput/stty can misreport inside nested terminals (tmux, some emulators),
  # so BUDDY_PANE_WIDTH lets you hard-code your pane's visible column count.
  if [ -n "${BUDDY_PANE_WIDTH:-}" ]; then
    COLS="$BUDDY_PANE_WIDTH"
  else
    COLS=$(stty size 2>/dev/null | awk '{print $2}')
    [ -z "$COLS" ] && COLS=$(tput cols 2>/dev/null || echo 80)
    # Safety margin: back off a couple cols so a slightly-stale width doesn't
    # push content over the edge. Cheap insurance; the visual difference at
    # the right edge is imperceptible.
    COLS=$((COLS - 2))
    [ "$COLS" -lt 20 ] && COLS=20
  fi

  # Periodic full-clear every Nth tick. Per-line \e[K + \e[J below catches
  # the common case, but pane resize (laptop dock/undock) and wide-character
  # overdraw can leave debris in rows we never re-render. ~once a minute at
  # default settings is enough to mop up without visible flicker.
  if [ "$BUDDY_PANE_CLEAR_EVERY" -gt 0 ] \
     && [ "$TICK" -ne 0 ] \
     && [ $((TICK % BUDDY_PANE_CLEAR_EVERY)) -eq 0 ]; then
    tput clear 2>/dev/null || printf '\033[2J\033[H'
  fi

  # Home the cursor instead of full-clear to avoid flicker, then move down
  # TOP_PADDING rows so the sprite sits lower in the pane. The top rows were
  # blanked by the initial clear and stay untouched.
  printf '\033[H'
  [ "$TOP_PADDING" -gt 0 ] && printf '\033[%sB' "$TOP_PADDING"
  # Feed empty stdin so the wrapper falls through to the no-session render path.
  # Append \033[K to each line so shrinking frames (bubble -> idle) don't leave
  # trailing characters from the previous, wider frame on the same row.
  COLUMNS="$COLS" node "$WRAPPER" </dev/null | sed $'s/$/\033[K/'
  # Clear from cursor to end-of-screen so shorter frames don't leave trails
  # *below* where the new frame ends.
  printf '\033[J'
  sleep "$INTERVAL"
  TICK=$((TICK + 1))
done
