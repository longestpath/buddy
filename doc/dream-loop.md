# Dream Loop — Self-Curating Animation Library

> A self-improving visual loop where the buddy MCP server proposes ASCII animations and the calling agent (the user's Claude Code session) acts as the evaluator. No outbound network, no Haiku API key, no sampling — leverages the agent already running in the user's session, same pattern as `buddy_observe` for character voice.

## Triggers

- **A — Manual.** `buddy_dream` MCP tool. Agent (or user via "tell my buddy to dream") explicitly invokes a dream cycle.
- **D — Idle playback.** During quiet periods (no recent `buddy_observe`), the MCP server occasionally schedules a library animation for playback by writing playback state to `buddy-status.json`. The statusline-wrapper picks it up on the next tick.

Skipped for v0: C (post-observe nudge).

## Loop

1. Agent calls `buddy_dream({brief?: string})`.
2. Server procedurally generates 4 candidate animations from species-specific building blocks (existing `SPRITE_BODIES` frames, eye-glyph palette, particle decorations, sequence templates).
3. Server returns candidates as labelled multi-line text plus a silent-mode instruction: pick the best, score 1–10, call `buddy_dream_commit` without narrating to the user.
4. Agent reads, picks, calls `buddy_dream_commit({chosen_id, score, notes?})`.
5. Server persists the winner in `species_animations`, drops losers, optionally starts immediate playback.

## Playback

Playback state lives in `buddy-status.json` under `playback`:

```json
{
  "playback": {
    "entry_id": "...",
    "frames": ["frame0...", "frame1..."],
    "started_at": 1730000000000,
    "duration_ms": 4000
  }
}
```

The statusline wrapper, on each tick, checks for active playback. If present and not yet expired, it renders the elapsed frame from the array. Otherwise it falls back to the normal species-profile-driven idle render. Playback overlay survives across wrapper ticks because it's persisted to the status file, not held in process memory.

## Schema

New table `species_animations`:

```sql
id TEXT PRIMARY KEY
species TEXT NOT NULL            -- e.g. "Axolotl"
frames TEXT NOT NULL              -- JSON: string[] (multi-line frames)
text TEXT DEFAULT ''              -- optional bubble text shown alongside
duration_ms INTEGER NOT NULL      -- total animation length
score INTEGER DEFAULT 5           -- agent-assigned 1-10
brief TEXT DEFAULT ''             -- the prompt that produced it
source TEXT DEFAULT 'dreamed'     -- 'dreamed' | 'seed'
created_at DATETIME DEFAULT CURRENT_TIMESTAMP
```

Per-species index for playback lookup. Per-companion preference scoring is *not* in v0 — animations are species-shared.

## Security

The MCP server stays `--network=none`. No new container, no host helper, no API keys. The agent (your Claude Code session) is the only thing with model access, and it already exists.

## Out of scope (v0)

- VHS-rendered GIFs as MCP image content (planned for follow-up, gated by `BUDDY_DREAM_VHS=1`).
- C trigger: post-observe nudges to dream.
- Per-companion preferences.
- Sharing libraries across users.
