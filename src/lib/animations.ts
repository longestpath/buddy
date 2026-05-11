// src/lib/animations.ts — CRUD + lookup over the species_animations table.

import { db } from '../db/schema.js';

export type StoredAnimation = {
  id: string;
  species: string;
  frames: string[];
  text: string;
  duration_ms: number;
  score: number;
  brief: string;
  source: 'dreamed' | 'seed';
  created_at: string;
};

type Row = {
  id: string;
  species: string;
  frames: string;        // JSON
  text: string;
  duration_ms: number;
  score: number;
  brief: string;
  source: string;
  created_at: string;
};

function rowToAnimation(row: Row): StoredAnimation {
  return {
    id: row.id,
    species: row.species,
    frames: JSON.parse(row.frames),
    text: row.text || '',
    duration_ms: row.duration_ms,
    score: row.score,
    brief: row.brief || '',
    source: (row.source === 'seed' ? 'seed' : 'dreamed') as 'dreamed' | 'seed',
    created_at: row.created_at,
  };
}

export function saveAnimation(a: Omit<StoredAnimation, 'created_at'>): void {
  db.prepare(
    `INSERT INTO species_animations (id, species, frames, text, duration_ms, score, brief, source)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).run(a.id, a.species, JSON.stringify(a.frames), a.text, a.duration_ms, a.score, a.brief, a.source);
}

export function listAnimations(species: string): StoredAnimation[] {
  const rows = db
    .prepare(`SELECT * FROM species_animations WHERE species = ? ORDER BY score DESC, created_at DESC`)
    .all(species) as Row[];
  return rows.map(rowToAnimation);
}

export function countAnimations(species: string): number {
  const row = db
    .prepare(`SELECT COUNT(*) as n FROM species_animations WHERE species = ?`)
    .get(species) as { n: number };
  return row.n;
}

/** Score-weighted random pick. Returns null if no animations exist for the species. */
export function pickWeightedAnimation(species: string): StoredAnimation | null {
  const entries = listAnimations(species);
  if (entries.length === 0) return null;
  // Weight by score, clamped to [1, 10] so a 1-scored animation still has a chance
  const weights = entries.map((e) => Math.max(1, Math.min(10, e.score)));
  const total = weights.reduce((a, b) => a + b, 0);
  let r = Math.random() * total;
  for (let i = 0; i < entries.length; i++) {
    r -= weights[i];
    if (r <= 0) return entries[i];
  }
  return entries[entries.length - 1];
}

export function deleteAnimation(id: string): void {
  db.prepare(`DELETE FROM species_animations WHERE id = ?`).run(id);
}

export function getAnimation(id: string): StoredAnimation | null {
  const row = db.prepare(`SELECT * FROM species_animations WHERE id = ?`).get(id) as Row | undefined;
  return row ? rowToAnimation(row) : null;
}
