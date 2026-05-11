// src/lib/dream.ts — Procedural candidate animation generation for the dream loop.
//
// The MCP server proposes; the calling agent disposes. No LLM here — just
// deterministic recombination of existing sprite material into novel sequences
// the agent can rank.

import { SPRITE_BODIES, renderSprite } from './species.js';
import { randomUUID } from 'crypto';
import type { Companion } from './types.js';

export type CandidateAnimation = {
  id: string;
  species: string;
  strategy: string;
  brief: string;
  frames: string[];        // each frame is a multi-line ASCII string
  duration_ms: number;
};

const EYE_PALETTE = ['×', '^', '·', 'o', 'O', '◉', '✦', '°', '*', '-', '"', 'ø'];
const PARTICLE_PALETTE = ['~', '·', '°', '*', '♪', '⚡', '○', '✿', '◇'];
const STRATEGIES = ['swim', 'bounce', 'flicker', 'explode', 'wiggle', 'spin'];

function pick<T>(arr: T[], rng: () => number): T {
  return arr[Math.floor(rng() * arr.length)];
}

function seededRng(seed: number): () => number {
  let s = seed >>> 0;
  if (s === 0) s = 0xdeadbeef;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

function spriteBones(c: Companion) {
  return {
    species: c.species,
    eye: c.eye,
    hat: 'none',
    rarity: c.rarity,
    shiny: c.shiny || false,
    stats: c.stats,
  } as any;
}

function widthOf(lines: string[]): number {
  return Math.max(0, ...lines.map((l) => l.length));
}

function padLines(lines: string[], width: number): string[] {
  return lines.map((l) => l + ' '.repeat(Math.max(0, width - l.length)));
}

function shiftRight(lines: string[], n: number): string[] {
  return lines.map((l) => ' '.repeat(Math.max(0, n)) + l);
}

function blankRow(width: number): string {
  return ' '.repeat(width);
}

function replaceEye(lines: string[], from: string, to: string): string[] {
  if (!from || from === to) return lines;
  return lines.map((l) => l.replaceAll(from, to));
}

// ── Strategy: swim ──
// Horizontal column-shift sweep, alternating between sprite frames if available.
function genSwim(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const baseFrames = SPRITE_BODIES[c.species] || [];
  const frameCount = baseFrames.length;
  const a = renderSprite(spriteBones(c), 0);
  const b = frameCount > 1 ? renderSprite(spriteBones(c), 1) : a;
  const positions = [0, 1, 3, 5, 6, 5, 3, 1];
  const out: string[] = [];
  for (let i = 0; i < positions.length; i++) {
    const body = i % 2 === 0 ? a : b;
    out.push(shiftRight(body, positions[i]).join('\n'));
  }
  return { id: randomUUID(), species: c.species, strategy: 'swim', brief, frames: out, duration_ms: positions.length * 250 };
}

// ── Strategy: bounce ──
// Vertical motion via blank-row padding.
function genBounce(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const body = renderSprite(spriteBones(c), 0);
  const w = widthOf(body);
  const padded = padLines(body, w);
  const heights = [0, 1, 2, 1, 0, 0, 1, 0];
  const out: string[] = [];
  for (const h of heights) {
    const blanks = Array(h).fill(blankRow(w));
    const tail = Array(2 - h).fill(blankRow(w));
    out.push([...blanks, ...padded, ...tail].join('\n'));
  }
  return { id: randomUUID(), species: c.species, strategy: 'bounce', brief, frames: out, duration_ms: heights.length * 220 };
}

// ── Strategy: flicker ──
// Hold position, cycle eye glyphs through palette.
function genFlicker(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const body = renderSprite(spriteBones(c), 0);
  // Pick 5 distinct eyes, weighted toward the buddy's actual eye for stability
  const eyes: string[] = [c.eye];
  while (eyes.length < 6) {
    const candidate = pick(EYE_PALETTE, rng);
    if (!eyes.includes(candidate)) eyes.push(candidate);
  }
  const out = eyes.map((e) => replaceEye(body, c.eye, e).join('\n'));
  return { id: randomUUID(), species: c.species, strategy: 'flicker', brief, frames: out, duration_ms: out.length * 280 };
}

// ── Strategy: explode ──
// Buddy intact, then progressively shattered/scattered.
function genExplode(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const body = renderSprite(spriteBones(c), 0);
  const w = widthOf(body);
  const out: string[] = [body.join('\n')];

  // Add a "compressed" frame
  const squished = body.map((l) => l.replace(/\s{2,}/g, ' '));
  out.push(squished.join('\n'));

  // Scatter: replace random non-space chars with particles, increasing intensity
  const intensities = [0.15, 0.35, 0.6, 0.9];
  for (const intensity of intensities) {
    const scattered = body
      .map((l) =>
        l
          .split('')
          .map((ch) => {
            if (ch === ' ') return ch;
            return rng() < intensity ? pick(PARTICLE_PALETTE, rng) : ch;
          })
          .join(''),
      )
      .join('\n');
    out.push(scattered);
  }

  // Final: empty, then a tiny "phoenix" particle cluster
  out.push(' '.repeat(w));
  const cluster = `   ${pick(PARTICLE_PALETTE, rng)}${pick(PARTICLE_PALETTE, rng)}${pick(PARTICLE_PALETTE, rng)}   `;
  out.push(cluster);

  return { id: randomUUID(), species: c.species, strategy: 'explode', brief, frames: out, duration_ms: out.length * 300 };
}

// ── Strategy: wiggle ──
// Tiny horizontal jitter, alternating one-col left and right.
function genWiggle(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const body = renderSprite(spriteBones(c), 0);
  const positions = [0, 1, 0, 1, 0, 2, 0, 1];
  const out = positions.map((p) => shiftRight(body, p).join('\n'));
  return { id: randomUUID(), species: c.species, strategy: 'wiggle', brief, frames: out, duration_ms: positions.length * 200 };
}

// ── Strategy: spin ──
// Cycle through sprite frames if multiple, with rotating eye glyphs to fake rotation.
function genSpin(c: Companion, brief: string, rng: () => number): CandidateAnimation {
  const baseFrames = SPRITE_BODIES[c.species] || [];
  const frameCount = Math.max(1, baseFrames.length);
  const eyes = ['·', 'o', 'O', '◉', 'O', 'o', '·', '-'];
  const out: string[] = [];
  for (let i = 0; i < eyes.length; i++) {
    const body = renderSprite(spriteBones(c), i % frameCount);
    out.push(replaceEye(body, c.eye, eyes[i]).join('\n'));
  }
  return { id: randomUUID(), species: c.species, strategy: 'spin', brief, frames: out, duration_ms: out.length * 230 };
}

const GENERATORS: Record<string, (c: Companion, brief: string, rng: () => number) => CandidateAnimation> = {
  swim: genSwim,
  bounce: genBounce,
  flicker: genFlicker,
  explode: genExplode,
  wiggle: genWiggle,
  spin: genSpin,
};

/**
 * Generate `count` candidate animations for a companion, using diverse strategies.
 * Deterministic given the same seed; different seeds produce different outputs
 * even from the same strategy (where the strategy is non-trivially randomized).
 */
export function generateCandidates(
  companion: Companion,
  brief = '',
  count = 4,
  seed = Date.now(),
): CandidateAnimation[] {
  const rng = seededRng(seed);
  // Shuffle strategies for variety, but bias toward the first 4
  const order = [...STRATEGIES].sort(() => rng() - 0.5);
  const chosen = order.slice(0, count);
  return chosen.map((strat) => GENERATORS[strat](companion, brief, rng));
}

/** Format a candidate for inclusion in an MCP tool text response. */
export function formatCandidate(c: CandidateAnimation): string {
  return [
    `── candidate: ${c.id} (strategy: ${c.strategy}, ${c.frames.length} frames, ${c.duration_ms}ms) ──`,
    ...c.frames.map((f, i) => `[frame ${i}]\n${f}`),
  ].join('\n\n');
}
