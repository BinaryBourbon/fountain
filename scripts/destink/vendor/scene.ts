// Scene — the decoupling seam. layout() runs once and produces a Scene;
// every renderer (Canvas now, WebGPU later) consumes the same Scene.
//
// Two rules that make "rich" possible:
//   (a) a tagged scene-*graph*, not a flat list (groups carry role + stable id)
//   (b) primitives carry *roles*, not pixels (Theme maps role -> appearance)

export type Pt = { x: number; y: number };

// Axis-aligned bounding box, in abstract layout units. Right/left may overhang the head.
export type BBox = { left: number; top: number; right: number; bottom: number };

// Identity back-references.
export type NodeId = string; // stable, STRUCTURAL (derived from IR path/role) — load-bearing for morph
export type IrId = string; // back-ref to the originating IR node

// The full alphabet of marks. Everything renders to a Seg or a Lbl.
export type Role =
  | "baseline"
  | "rail"
  | "divider.full"
  | "divider.half"
  | "divider.lean"
  | "slant"
  | "word"
  | "connector.dotted"
  | "fork";

export type Prim =
  | { kind: "seg"; a: Pt; b: Pt; role: Role; sourceId?: IrId }
  | { kind: "lbl"; text: string; anchor: Pt; angle: number; role: Role; pos?: string; sourceId?: IrId }; // pos: POS tag when the label is a single leaf word

export type NodeRole =
  | "sentence"
  | "clause"
  | "subject"
  | "verb"
  | "object"
  | "complement"
  | "modifier"
  | "pp"
  | "compound"
  | "subclause";

export type SceneNode = {
  id: NodeId;
  role: NodeRole;
  sourceId?: IrId;
  children: Array<SceneNode | Prim>;
  bounds: BBox;
};

export type Scene = { root: SceneNode; bounds: BBox };

// --- small helpers ---

export const isNode = (c: SceneNode | Prim): c is SceneNode =>
  (c as SceneNode).children !== undefined;

export const emptyBBox = (): BBox => ({
  left: Infinity,
  top: Infinity,
  right: -Infinity,
  bottom: -Infinity,
});

// --- fit-to-canvas view transform (scene units -> screen px). Shared by the renderer and by
// pointer hit-testing so they never drift. Only ever scales DOWN, and centres the diagram. ---
export type View = { s: number; tx: number; ty: number };

export const fitView = (b: BBox, cssW: number, cssH: number, pad = 28): View => {
  const bw = Math.max(1, b.right - b.left);
  const bh = Math.max(1, b.bottom - b.top);
  const s = Math.min(1, (cssW - 2 * pad) / bw, (cssH - 2 * pad) / bh);
  return { s, tx: (cssW - bw * s) / 2 - b.left * s, ty: (cssH - bh * s) / 2 - b.top * s };
};

export const screenToScene = (p: Pt, v: View): Pt => ({ x: (p.x - v.tx) / v.s, y: (p.y - v.ty) / v.s });
