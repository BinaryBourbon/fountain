// Inspector — read a laid-out Scene and describe its parts by grammatical role. Two entry points
// over one walk:
//   describeAll(scene) -> every word and line, with role + geometry + owning node id. The
//     game-agnostic "truth" layer: an "identify the type" mode picks quiz targets from it; a
//     "drag the words in" or "fill your own words" mode reads word slots (anchor + role) from it.
//   describeAt(scene, point) -> the single element under a point (hover tooltips).
// Pure and renderer-agnostic: role comes from each element's own role plus its ancestor node roles.

import type { Scene, SceneNode, Pt, NodeRole, Role, NodeId, BBox } from "./scene.js";
import { isNode } from "./scene.js";
import type { TextMetrics } from "./layout.js";

export type Inspection = { title: string; detail: string; kind: "word" | "line" };

// A word slot: its correct text, its role, where it sits, and its owning node.
export type WordElement = {
  kind: "word";
  text: string;
  pos?: string; // Penn-Treebank POS tag (NN, JJ, RB…) when the word is a single leaf
  role: string; // human name, e.g. "Direct object"
  roleKey: NodeRole; // machine key of the nearest role, e.g. "object"
  roles: NodeRole[]; // full ancestor chain (root -> element), so callers can tell a direct object from a preposition's object
  detail: string;
  nodeId: NodeId;
  anchor: Pt;
  angle: number;
  width: number;
  bbox: BBox; // axis-aligned bounds (hotspots / drop targets)
};
export type LineElement = {
  kind: "line";
  role: string;
  roleKey: Role;
  roles: NodeRole[];
  detail: string;
  nodeId: NodeId;
  a: Pt;
  b: Pt;
  bbox: BBox;
};
export type SceneElement = WordElement | LineElement;

// What each grammatical slot means, keyed by the node role a word sits in.
const ROLE: Partial<Record<NodeRole, { name: string; detail: string }>> = {
  subject: { name: "Subject", detail: "The noun or pronoun the sentence is about." },
  verb: { name: "Verb", detail: "The predicate — the action or state, right of the subject divider." },
  object: { name: "Direct object", detail: "Receives the action of the verb, after the verb–object divider." },
  complement: { name: "Complement", detail: "A predicate noun/adjective or an objective complement." },
  modifier: { name: "Modifier", detail: "An adjective, adverb, or article, on a slant under the word it modifies." },
  pp: { name: "Prepositional phrase", detail: "A preposition on the slant, its object on the line below." },
  subclause: { name: "Subordinate clause", detail: "A clause used as a modifier or noun, on a dotted connector." },
  compound: { name: "Compound", detail: "Coordinated parts joined by a conjunction on a fork." },
  clause: { name: "Clause", detail: "A subject–predicate unit." },
  sentence: { name: "Sentence", detail: "The whole diagram." },
};

// What each line means, keyed by the segment role (slant refined by context below).
const LINE: Record<Role, { name: string; detail: string }> = {
  baseline: { name: "Baseline", detail: "The horizontal line the words sit on." },
  rail: { name: "Rail", detail: "A supporting horizontal line (a stand or a raised platform)." },
  "divider.full": { name: "Subject | Predicate divider", detail: "The full vertical bar splitting subject from verb." },
  "divider.half": { name: "Verb | Object divider", detail: "The half bar before a direct object." },
  "divider.lean": { name: "Complement divider", detail: "The back-slanting line before a predicate noun/adjective or objective complement." },
  slant: { name: "Modifier line", detail: "Slants down from a word to the modifier hanging on it." },
  word: { name: "Word", detail: "A diagrammed word." },
  "connector.dotted": { name: "Connector", detail: "Links a subordinate/relative clause or a conjunction." },
  fork: { name: "Fork", detail: "Joins the coordinated parts of a compound." },
};
const PREP_LINE = { name: "Preposition line", detail: "Carries the preposition; its object sits on the line at the foot." };

// Friendly name for a Penn-Treebank POS tag (prefix-matched), for tooltips and "what part of
// speech is this?" prompts.
const POS_NAMES: Array<[string, string]> = [
  ["NNP", "proper noun"], ["NN", "noun"], ["JJ", "adjective"], ["RB", "adverb"],
  ["PRP$", "possessive"], ["PRP", "pronoun"], ["VB", "verb"], ["MD", "modal verb"],
  ["DT", "article"], ["IN", "preposition"], ["TO", "to"], ["CC", "conjunction"],
  ["CD", "number"], ["WP", "wh-word"], ["WDT", "wh-word"], ["WRB", "wh-word"],
];
export const posName = (tag?: string): string | undefined => (tag ? POS_NAMES.find(([p]) => tag.startsWith(p))?.[1] : undefined);

const nearestRole = (chain: NodeRole[]): NodeRole => {
  for (let i = chain.length - 1; i >= 0; i--) if (ROLE[chain[i]!]) return chain[i]!;
  return "sentence";
};

function wordCorners(anchor: Pt, angle: number, width: number, ascent: number, descent: number): Pt[] {
  const c = Math.cos(angle), s = Math.sin(angle);
  const local: Array<[number, number]> = [[0, -ascent], [width, -ascent], [width, descent], [0, descent]];
  return local.map(([lx, ly]) => ({ x: anchor.x + lx * c - ly * s, y: anchor.y + lx * s + ly * c }));
}

const aabb = (pts: Pt[]): BBox => ({
  left: Math.min(...pts.map((p) => p.x)),
  top: Math.min(...pts.map((p) => p.y)),
  right: Math.max(...pts.map((p) => p.x)),
  bottom: Math.max(...pts.map((p) => p.y)),
});

function pointInQuad(p: Pt, q: Pt[]): boolean {
  let sign = 0;
  for (let i = 0; i < 4; i++) {
    const a = q[i]!, b = q[(i + 1) % 4]!;
    const cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
    if (cross !== 0) {
      const sg = Math.sign(cross);
      if (sign === 0) sign = sg;
      else if (sg !== sign) return false;
    }
  }
  return true;
}

function distToSeg(p: Pt, a: Pt, b: Pt): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len2 = dx * dx + dy * dy || 1;
  const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

// Every word and line in the scene, with its role and geometry.
export function describeAll(scene: Scene, m: TextMetrics, sizePx: number): SceneElement[] {
  const out: SceneElement[] = [];
  (function walk(n: SceneNode, roles: NodeRole[]): void {
    const chain = [...roles, n.role];
    for (const c of n.children) {
      if (isNode(c)) walk(c, chain);
      else if (c.kind === "lbl" && c.text) {
        const rk = nearestRole(chain);
        const r = ROLE[rk]!;
        const { width, ascent, descent } = m.measure(c.text, sizePx);
        const corners = wordCorners(c.anchor, c.angle, width, ascent, descent);
        out.push({ kind: "word", text: c.text, ...(c.pos ? { pos: c.pos } : {}), role: r.name, roleKey: rk, roles: chain, detail: r.detail, nodeId: n.id, anchor: c.anchor, angle: c.angle, width, bbox: aabb(corners) });
      } else if (c.kind === "seg") {
        const r = c.role === "slant" && chain.includes("pp") ? PREP_LINE : LINE[c.role];
        out.push({ kind: "line", role: r.name, roleKey: c.role, roles: chain, detail: r.detail, nodeId: n.id, a: c.a, b: c.b, bbox: aabb([c.a, c.b]) });
      }
    }
  })(scene.root, []);
  return out;
}

// The element under a point (word boxes win over nearby lines). Reuses describeAll's records.
export function describeAt(scene: Scene, p: Pt, m: TextMetrics, sizePx: number, lineTol = 5): Inspection | null {
  const state: { best: { d: number; el: SceneElement } | null } = { best: null };
  const consider = (d: number, el: SceneElement) => { if (!state.best || d < state.best.d) state.best = { d, el }; };
  for (const el of describeAll(scene, m, sizePx)) {
    if (el.kind === "word") {
      const { ascent, descent } = m.measure(el.text, sizePx);
      if (pointInQuad(p, wordCorners(el.anchor, el.angle, el.width, ascent, descent))) consider(0, el);
    } else {
      const d = distToSeg(p, el.a, el.b);
      if (d <= lineTol) consider(1 + d, el); // words (d=0) win over lines
    }
  }
  const el = state.best?.el;
  if (!el) return null;
  if (el.kind === "line") return { title: el.role, detail: el.detail, kind: "line" };
  const pn = posName(el.pos);
  return { title: `${el.text} · ${el.role}`, detail: pn ? `${pn} — ${el.detail}` : el.detail, kind: "word" };
}
