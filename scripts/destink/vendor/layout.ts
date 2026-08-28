// Layout — measure/arrange with a 2-D footprint. The novel, risky core (Phase 3), extended
// in Phase 4 with compounds (forks) and subordinate clauses (nesting).
//
// Key Phase-4 refactor: clause arrangement is itself a `Measured`, so a clause nests inside a
// clause with no special-casing. Every Measured bakes its id + NodeRole at measure time and
// exposes place(x, y) -> SceneNode. The engine is closed over an injected TextMetrics port.

import type { Clause, Nominal, Verbal, Modifier, Word, Compound, Sentence, Infinitive, Subject, PredicatePart } from "./ir.js";
import type { Scene, SceneNode, Prim, BBox, Pt, NodeId, NodeRole } from "./scene.js";
import type { LayoutStyle } from "./theme.js";
import { defaultLayoutStyle } from "./theme.js";

// The one genuinely backend-specific concern in layout; inject it as a port.
export interface TextMetrics {
  measure(text: string, sizePx: number): { width: number; ascent: number; descent: number };
}

// Browser adapter — shared by every renderer (same fonts -> same coordinates).
export class CanvasTextMetrics implements TextMetrics {
  private g: CanvasRenderingContext2D;
  constructor(private family = "Tinos, Georgia, 'Times New Roman', serif") {
    const c = document.createElement("canvas");
    const ctx = c.getContext("2d");
    if (!ctx) throw new Error("2D canvas context unavailable for text metrics");
    this.g = ctx;
  }
  measure(text: string, sizePx: number) {
    this.g.font = `${sizePx}px ${this.family}`;
    const m = this.g.measureText(text);
    return {
      width: m.width,
      ascent: m.actualBoundingBoxAscent ?? sizePx * 0.8,
      descent: m.actualBoundingBoxDescent ?? sizePx * 0.2,
    };
  }
}

// measure() result: horizontal room on the rail + the below-cluster bbox (relative to the
// left anchor at (0,0), baseline y=0) + a closure that emits absolute geometry. id + role baked.
export type Measured = {
  width: number;
  below: BBox;
  place: (x: number, y: number) => SceneNode;
};

const BASE_Y = 250;
const START_X = 200;

const box = (l: number, t: number, r: number, b: number): BBox => ({ left: l, top: t, right: r, bottom: b });
const unionB = (a: BBox, b: BBox): BBox => ({
  left: Math.min(a.left, b.left),
  top: Math.min(a.top, b.top),
  right: Math.max(a.right, b.right),
  bottom: Math.max(a.bottom, b.bottom),
});

export function layout(input: Clause | Sentence, metrics: TextMetrics, style: LayoutStyle = defaultLayoutStyle): Scene {
  const SZ = style.em;
  const w = (t: string) => metrics.measure(t, SZ).width;
  const cos = Math.cos(style.slantAngle);
  const sin = Math.sin(style.slantAngle);
  const MARGIN = style.pad;

  const lblBox = (anchor: Pt, text: string, angle: number): BBox => {
    const tw = w(text);
    const ex = anchor.x + tw * Math.cos(angle);
    const ey = anchor.y + tw * Math.sin(angle);
    return box(Math.min(anchor.x, ex), Math.min(anchor.y - SZ, ey - SZ), Math.max(anchor.x, ex), Math.max(anchor.y + 2, ey + 2));
  };
  const primBox = (p: Prim): BBox =>
    p.kind === "seg"
      ? box(Math.min(p.a.x, p.b.x), Math.min(p.a.y, p.b.y), Math.max(p.a.x, p.b.x), Math.max(p.a.y, p.b.y))
      : lblBox(p.anchor, p.text, p.angle);
  const childrenBox = (cs: Array<SceneNode | Prim>): BBox =>
    cs.map((c) => ("children" in c ? c.bounds : primBox(c))).reduce(unionB);

  // --- a modifier hanging below a head, measured relative to its attach point at (0,0) ---
  type MeasuredMod = { below: BBox; place: (ax: number, by: number) => SceneNode };

  function measureMod(m: Modifier, idPath: NodeId): MeasuredMod {
    if (m.kind === "word") {
      const text = m.value.text;
      const pos = m.value.pos;
      const L = w(text) + style.pad;
      const dx = L * cos;
      const dy = L * sin;
      return {
        below: box(0, 0, dx, dy),
        place: (ax, by) => {
          const slant: Prim = { kind: "seg", a: { x: ax, y: by }, b: { x: ax + dx, y: by + dy }, role: "slant" };
          const lbl: Prim = { kind: "lbl", text, anchor: { x: ax + 6 * cos, y: by + 6 * sin }, angle: style.slantAngle, role: "word", ...(pos ? { pos } : {}) };
          const ch: Array<SceneNode | Prim> = [slant, lbl];
          return { id: idPath, role: "modifier", children: ch, bounds: childrenBox(ch) };
        },
      };
    }
    if (m.kind === "prep") {
      const prep = m.prep.text;
      // slant must be LONGER than the preposition label so the object on the horizontal at its
      // foot doesn't collide with the label ("of" overlapping "Request").
      const L = w(prep) + style.em * 1.6;
      const dx = L * cos;
      const dy = L * sin;
      const obj = measureHead(m.object.head.text, m.object.modifiers, `${idPath}/obj`, "object"); // recursion
      const objBelow = box(dx + obj.below.left, dy + obj.below.top, dx + obj.below.right, dy + obj.below.bottom);
      return {
        below: unionB(box(0, 0, dx, dy), objBelow),
        place: (ax, by) => {
          const P = { x: ax + dx, y: by + dy };
          const slant: Prim = { kind: "seg", a: { x: ax, y: by }, b: P, role: "slant" };
          const prepLbl: Prim = { kind: "lbl", text: prep, anchor: { x: ax + 6 * cos, y: by + 6 * sin }, angle: style.slantAngle, role: "word" };
          const ch: Array<SceneNode | Prim> = [slant, prepLbl, obj.place(P.x, P.y)];
          return { id: idPath, role: "pp", children: ch, bounds: childrenBox(ch) };
        },
      };
    }
    if (m.kind === "participle") {
      // a participle hangs under the noun on a bent line: a short slant down to a horizontal rail
      // carrying the participle verb (+ object) with its own modifiers below.
      const core = measureVerbalCore(m.verb.text, m.modifiers, m.object, `${idPath}/p`);
      const L = style.em * 1.6;
      const dx = L * cos;
      const dy = L * sin;
      const coreBelow = box(dx + core.below.left, dy + core.below.top, dx + core.below.right, dy + core.below.bottom);
      return {
        below: unionB(box(0, 0, dx, dy), coreBelow),
        place: (ax, by) => {
          const P = { x: ax + dx, y: by + dy };
          const slant: Prim = { kind: "seg", a: { x: ax, y: by }, b: P, role: "slant" };
          const ch: Array<SceneNode | Prim> = [slant, core.place(P.x, P.y)];
          return { id: idPath, role: "pp", children: ch, bounds: childrenBox(ch) };
        },
      };
    }
    // subordinate / relative clause: nested clause below the head on a dotted connector.
    const nested = measureClause(m.value, `${idPath}/c`, "subclause");
    const conn = m.connector.text;
    const DROP = style.em * 3.6; // clear sibling modifier slants on the same head
    return {
      below: unionB(box(0, 0, 0, DROP), box(nested.below.left, DROP + nested.below.top, Math.max(nested.width, nested.below.right), DROP + nested.below.bottom)),
      place: (ax, by) => {
        const drop: Pt = { x: ax, y: by + DROP };
        const dotted: Prim = { kind: "seg", a: { x: ax, y: by }, b: drop, role: "connector.dotted" };
        const connLbl: Prim = { kind: "lbl", text: conn, anchor: { x: ax + 4, y: by + DROP * 0.5 }, angle: 0, role: "word" };
        const ch: Array<SceneNode | Prim> = [dotted, connLbl, nested.place(ax, by + DROP)];
        return { id: idPath, role: "subclause", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // --- a head word + its hanging modifiers, occupying [x, x+width] on the baseline ---
  function measureHead(headText: string, mods: Modifier[], idPath: NodeId, role: NodeRole, appositive?: string, headPos?: string): Measured {
    if (appositive) headText = `${headText} (${appositive})`; // R-K: apposition in parens on the rail
    const headW = w(headText);
    const mm = mods.map((m, i) => ({ i, m: measureMod(m, `${idPath}/m${i}`) }));
    // Place modifiers left-to-right, each reserving its OWN footprint width, so a wide modifier
    // (a PP or a relative clause) doesn't overlap its neighbors.
    const attaches: number[] = [];
    let ax = style.pad;
    for (const { m } of mm) {
      attaches.push(ax);
      ax += Math.max(style.minSlantSpacing, m.below.right - m.below.left) + style.pad; // breathing room between modifiers
    }
    // The rail spans at least to the last modifier's attach point, so the divider that follows the
    // word lands clear of the modifier fan (a short adjective slant must not cross the divider).
    // Wide modifiers (PP/clause) still overhang further via `below`, so they keep pushing neighbors.
    const lastAttach = attaches.length ? attaches[attaches.length - 1]! : 0;
    const segW = Math.max(headW, lastAttach + style.minSlantSpacing) + style.pad;

    let below = box(0, 0, segW, 0);
    mm.forEach(({ m }, k) => {
      const a = attaches[k]!;
      below = unionB(below, box(a + m.below.left, m.below.top, a + m.below.right, m.below.bottom));
    });

    return {
      width: segW,
      below,
      place: (x, y) => {
        const rail: Prim = { kind: "seg", a: { x, y }, b: { x: x + segW, y }, role: "baseline" };
        const headLbl: Prim = { kind: "lbl", text: headText, anchor: { x: x + segW / 2 - headW / 2, y: y - 4 }, angle: 0, role: "word", ...(headPos ? { pos: headPos } : {}) };
        const modNodes = mm.map(({ m }, k) => m.place(x + attaches[k]!, y));
        const ch: Array<SceneNode | Prim> = [rail, headLbl, ...modNodes];
        return { id: idPath, role, children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // --- a compound head slot: N branches forked to a single apex on the main rail ---
  // openRight=true  -> apex on the right (a SUBJECT connects rightward to the divider).
  // openRight=false -> apex on the left  (an OBJECT/COMPLEMENT/VERB connects leftward to it).
  function measureCompound(branches: Measured[], conj: string, idPath: NodeId, openRight: boolean): Measured {
    const n = branches.length;
    // Adjacent branches must clear each other's hanging modifiers: a branch whose adjectives fan
    // below needs the next branch's rail placed past that fan, else "strong" collides with "figure".
    const maxDrop = Math.max(0, ...branches.map((b) => b.below.bottom));
    const SP = Math.max(style.em * 2.2, maxDrop + style.em * 1.6); // vertical gap between adjacent branches
    const offAt = (i: number) => (i - (n - 1) / 2) * SP;
    const maxW = Math.max(...branches.map((b) => b.width));
    // The fork region between the branches and the apex must be long enough to hold the conjunction
    // label, so a long correlative ("both...and") fits there instead of spilling into the divider.
    const forkLen = Math.max(style.em * 1.6, w(conj) + style.pad * 2);
    const width = maxW + forkLen;
    const bx0 = openRight ? 0 : forkLen; // branch baseline left offset

    let below = box(0, offAt(0), width, offAt(n - 1));
    branches.forEach((b, i) => {
      const off = offAt(i);
      below = unionB(below, box(bx0 + b.below.left, off + b.below.top, bx0 + b.below.right, off + b.below.bottom));
    });

    return {
      width,
      below,
      place: (x, y) => {
        const apex: Pt = openRight ? { x: x + width, y } : { x, y };
        const ch: Array<SceneNode | Prim> = [];
        branches.forEach((b, i) => {
          const by = y + offAt(i);
          ch.push(b.place(x + bx0, by));
          const connect: Pt = openRight ? { x: x + bx0 + b.width, y: by } : { x: x + bx0, y: by };
          ch.push({ kind: "seg", a: connect, b: apex, role: "fork" });
        });
        const bx = x + bx0 + (openRight ? maxW : 0); // dotted conjunction bridge near the fork
        ch.push({ kind: "seg", a: { x: bx, y: y + offAt(0) }, b: { x: bx, y: y + offAt(n - 1) }, role: "connector.dotted" });
        // label sits in the fork region, away from the apex: rightward for a subject (apex right),
        // leftward for an object (apex left) — so it clears both the divider and the branches.
        const conjX = openRight ? bx + 4 : bx - w(conj) - 4;
        ch.push({ kind: "lbl", text: conj, anchor: { x: conjX, y }, angle: 0, role: "word" });
        return { id: idPath, role: "compound", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // Mount an inner diagram on a stand: a base rail on the main line, a stilt rising to the raised
  // inner diagram. Used for a verbal/clause filling a nominal slot ("Running marathons is fun").
  function measureOnStand(inner: Measured, idPath: NodeId, role: NodeRole, connectRight: boolean): Measured {
    // Raise the platform above everything that hangs below the inner diagram, so its modifiers
    // clear the base rail and the main clause's divider.
    const STAND_H = Math.max(style.em * 3.6, inner.below.bottom + style.em * 1.4);
    return {
      width: inner.width,
      below: box(Math.min(0, inner.below.left), -STAND_H + inner.below.top - SZ, Math.max(inner.width, inner.below.right), Math.max(0, inner.below.bottom - STAND_H)),
      place: (x, y) => {
        const ry = y - STAND_H;
        // A subject stand's base runs to the divider on its right; an object/complement stand
        // connects on its LEFT (via the half-divider), so it needs only a short foot — not a
        // full-width bar under the whole raised clause.
        const baseRight = connectRight ? x + inner.width : x + style.pad * 2;
        const ch: Array<SceneNode | Prim> = [
          { kind: "seg", a: { x, y }, b: { x: baseRight, y }, role: "baseline" }, // base / foot on the main line
          { kind: "seg", a: { x: x + style.pad, y }, b: { x: x + style.pad, y: ry }, role: "rail" }, // stilt at the left
          inner.place(x, ry),
        ];
        return { id: idPath, role, children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // A verbal core "verb [│ object]" with modifiers below the verb — the raised content of a gerund.
  function measureVerbalCore(headText: string, mods: Modifier[], object: Nominal | null, idPath: NodeId): Measured {
    const headM = measureHead(headText, mods, `${idPath}/h`, "verb");
    if (!object) return headM;
    const objM = measureHead(object.head.text, object.modifiers, `${idPath}/o`, "object");
    const objLeft = headM.width + style.dividerGap;
    const width = objLeft + objM.width;
    const below = unionB(headM.below, box(objLeft + objM.below.left, objM.below.top, objLeft + objM.below.right, objM.below.bottom));
    return {
      width,
      below,
      place: (x, y) => {
        const dx = x + headM.width + style.dividerGap / 2;
        const ch: Array<SceneNode | Prim> = [
          headM.place(x, y),
          { kind: "seg", a: { x: dx, y: y - style.halfDividerRise }, b: { x: dx, y }, role: "divider.half" },
          objM.place(x + objLeft, y),
        ];
        return { id: idPath, role: "verb", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // A compound-predicate branch: a verb rail then its OWN complement (each conjunct of "has black
  // fur and can jump high" carries its object). Mirrors the verb+complement spacing of a clause.
  function measurePredicatePart(part: PredicatePart, idPath: NodeId): Measured {
    const verbM = measureHead(part.verb.head.text, part.verb.modifiers, `${idPath}/v`, "verb");
    if (!part.complement) return verbM;
    const c = measureComplement(part.complement, idPath);
    const cLeft = Math.max(verbM.width + style.dividerGap, verbM.below.right + MARGIN - c.measured.below.left);
    const dx = (verbM.width + cLeft) / 2;
    const below = unionB(verbM.below, box(cLeft + c.measured.below.left, c.measured.below.top, cLeft + c.measured.below.right, c.measured.below.bottom));
    return {
      width: cLeft + c.measured.width,
      below,
      place: (x, y) => {
        const ch: Array<SceneNode | Prim> = [verbM.place(x, y)];
        const dxa = x + dx;
        if (c.divider === "half") ch.push({ kind: "seg", a: { x: dxa, y: y - style.halfDividerRise }, b: { x: dxa, y }, role: "divider.half" });
        else {
          const len = style.halfDividerRise / Math.sin(style.leanLeftAngle);
          ch.push({ kind: "seg", a: { x: dxa, y }, b: { x: dxa - len * Math.cos(style.leanLeftAngle), y: y - len * Math.sin(style.leanLeftAngle) }, role: "divider.lean" });
        }
        ch.push(c.measured.place(x + cLeft, y));
        return { id: idPath, role: "verb", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // --- a head slot that may be single or compound, or a stand-mounted verbal/clause ---
  function measureFiller(slot: Subject | Verbal | Compound<PredicatePart>, idPath: NodeId, role: NodeRole, openRight: boolean): Measured {
    if ("kind" in slot) {
      // gerund / infinitive filling a nominal slot: a verbal core raised on a stand.
      const head = slot.kind === "infinitive" ? `to ${slot.verb.text}` : slot.verb.text;
      return measureOnStand(measureVerbalCore(head, slot.modifiers, slot.object, `${idPath}/v`), idPath, role, openRight);
    }
    if ("subject" in slot) return measureOnStand(measureClause(slot, `${idPath}/nc`, "clause"), idPath, role, openRight); // noun clause
    if ("items" in slot) {
      const items = slot.items;
      // compound predicate: each branch is a verb + its own complement
      if (items.length && "verb" in items[0]!) {
        const parts = items as PredicatePart[];
        if (parts.length === 1) return measurePredicatePart(parts[0]!, idPath);
        const branches = parts.map((p, i) => measurePredicatePart(p, `${idPath}/b${i}`));
        return measureCompound(branches, slot.conjunction.text, idPath, openRight);
      }
      // compound of nominals (subject / object)
      const noms = items as Nominal[];
      const appOf = (it: Nominal): string | undefined => it.appositive?.text;
      if (noms.length === 1) return measureHead(noms[0]!.head.text, noms[0]!.modifiers, idPath, role, appOf(noms[0]!), noms[0]!.head.pos);
      const branches = noms.map((it, i) => measureHead(it.head.text, it.modifiers, `${idPath}/b${i}`, role, appOf(it), it.head.pos));
      return measureCompound(branches, slot.conjunction.text, idPath, openRight);
    }
    // An indirect object hangs below the verb on a slant + rail — an implied-preposition PP.
    const io = "indirectObject" in slot ? slot.indirectObject : undefined;
    const mods: Modifier[] = io ? [...slot.modifiers, { kind: "prep", prep: { text: "" }, object: io }] : slot.modifiers;
    return measureHead(slot.head.text, mods, idPath, role, "appositive" in slot ? slot.appositive?.text : undefined, slot.head.pos);
  }

  // An infinitive object on a STAND: a post rises from the object slot to a raised rail that
  // carries "to" (on a slant) + the verb, with the verb's own object after a half-divider.
  function measureInfinitive(inf: Infinitive, idPath: NodeId): Measured {
    const STAND_H = style.em * 3.4;
    const verbW = w(inf.verb.text);
    const toW = w("to");
    const objM = inf.object ? measureHead(inf.object.head.text, inf.object.modifiers, `${idPath}/o`, "object") : null;
    const railW = style.pad + verbW + (objM ? style.dividerGap + objM.width : 0) + style.pad;
    return {
      width: railW,
      below: box(-toW, -(STAND_H + SZ * 2), railW, 0), // sits entirely above the baseline
      place: (x, y) => {
        const ry = y - STAND_H; // raised rail of the infinitive
        const sx = x + style.pad; // stand post + rail left
        const ch: Array<SceneNode | Prim> = [];
        ch.push({ kind: "seg", a: { x: sx, y }, b: { x: sx, y: ry }, role: "rail" }); // stand post
        ch.push({ kind: "seg", a: { x: sx - 5, y }, b: { x: sx + 5, y }, role: "rail" }); // foot
        ch.push({ kind: "seg", a: { x: sx, y: ry }, b: { x: sx + railW, y: ry }, role: "baseline" }); // raised rail
        ch.push({ kind: "seg", a: { x: sx - toW * 0.7, y: ry + toW * 0.7 }, b: { x: sx, y: ry }, role: "slant" }); // "to" slant
        ch.push({ kind: "lbl", text: "to", anchor: { x: sx - toW * 0.7 + 2, y: ry + toW * 0.7 - 3 }, angle: style.slantAngle, role: "word" });
        ch.push({ kind: "lbl", text: inf.verb.text, anchor: { x: sx + style.pad, y: ry - 4 }, angle: 0, role: "word" });
        if (objM) {
          const dx = sx + style.pad + verbW + style.dividerGap / 2;
          ch.push({ kind: "seg", a: { x: dx, y: ry - style.halfDividerRise }, b: { x: dx, y: ry }, role: "divider.half" });
          ch.push(objM.place(sx + style.pad + verbW + style.dividerGap, ry));
        }
        return { id: idPath, role: "object", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  // An objective complement lays out as one horizontal unit: the direct object, a back-leaning
  // divider (tilting toward the object it describes), then the complement noun/adjective.
  function measureObjectComplement(oc: Extract<NonNullable<Clause["complement"]>, { kind: "objectComplement" }>, idPath: NodeId): Measured {
    const objM = measureFiller(oc.object, `${idPath}/do`, "object", false);
    const ocM = oc.ocIsAdj
      ? measureHead((oc.oc as Word).text, [], `${idPath}/oc`, "complement")
      : measureFiller(oc.oc as Nominal, `${idPath}/oc`, "complement", false);
    const ocLeft = objM.width + style.dividerGap;
    const width = ocLeft + ocM.width;
    const below = unionB(objM.below, box(ocLeft + ocM.below.left, ocM.below.top, ocLeft + ocM.below.right, ocM.below.bottom));
    return {
      width,
      below,
      place: (x, y) => {
        const dx = x + objM.width + style.dividerGap / 2;
        const len = style.halfDividerRise / Math.sin(style.leanLeftAngle);
        const ch: Array<SceneNode | Prim> = [
          objM.place(x, y),
          { kind: "seg", a: { x: dx, y }, b: { x: dx - len * Math.cos(style.leanLeftAngle), y: y - len * Math.sin(style.leanLeftAngle) }, role: "divider.lean" },
          ocM.place(x + ocLeft, y),
        ];
        return { id: idPath, role: "complement", children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  type CompM = { divider: "half" | "lean"; measured: Measured };
  function measureComplement(c: NonNullable<Clause["complement"]>, idPrefix: NodeId): CompM {
    if (c.kind === "objectComplement") return { divider: "half", measured: measureObjectComplement(c, `${idPrefix}/oc`) };
    if (c.kind === "directObject") {
      if ("kind" in c.value) return { divider: "half", measured: measureInfinitive(c.value, `${idPrefix}/inf`) }; // only Infinitive has `kind`
      return { divider: "half", measured: measureFiller(c.value, `${idPrefix}/obj`, "object", false) };
    }
    if (c.kind === "predicateNoun") return { divider: "lean", measured: measureFiller(c.value, `${idPrefix}/pn`, "complement", false) };
    // predicate adjective — single word, or a fork ("tiny and loud")
    if ("items" in c.value) {
      const branches = c.value.items.map((wd, i) => measureHead(wd.text, [], `${idPrefix}/pa/b${i}`, "complement"));
      return { divider: "lean", measured: measureCompound(branches, c.value.conjunction.text, `${idPrefix}/pa`, false) };
    }
    return { divider: "lean", measured: measureHead(c.value.text, [], `${idPrefix}/pa`, "complement") };
  }

  // --- a whole clause as a placeable unit (so clauses nest in clauses) ---
  function measureClause(clause: Clause, idPrefix: NodeId, role: NodeRole): Measured {
    const subj = measureFiller(clause.subject, `${idPrefix}/subj`, "subject", true); // apex right -> divider
    const verb = measureFiller(clause.verb, `${idPrefix}/verb`, "verb", false); // apex left <- divider
    const comp = clause.complement ? measureComplement(clause.complement, idPrefix) : null;

    const subjRight = subj.width;
    // THE CRUX: spacing respects both the divider minimum AND below-cluster overlap. The full
    // divider must also sit clear of anything hanging below the subject (a wide participle/PP),
    // so no modifier line crosses it; the verb then follows the divider.
    const fullX = Math.max(subjRight + style.dividerGap / 2, subj.below.right + style.pad);
    const verbLeft = Math.max(fullX + style.dividerGap / 2, subj.below.right + MARGIN - verb.below.left);
    const verbRight = verbLeft + verb.width;

    let compLeft = 0;
    let compDx = 0;
    let totalRight = verbRight;
    if (comp) {
      const verbClusterR = verbLeft + verb.below.right;
      compLeft = Math.max(verbRight + style.dividerGap, verbClusterR + MARGIN - comp.measured.below.left);
      compDx = (verbRight + compLeft) / 2;
      totalRight = compLeft + comp.measured.width;
    }

    let below = unionB(subj.below, box(verbLeft + verb.below.left, verb.below.top, verbLeft + verb.below.right, verb.below.bottom));
    if (comp) below = unionB(below, box(compLeft + comp.measured.below.left, comp.measured.below.top, compLeft + comp.measured.below.right, comp.measured.below.bottom));

    return {
      width: totalRight,
      below,
      place: (x, y) => {
        const ch: Array<SceneNode | Prim> = [
          subj.place(x, y),
          { kind: "seg", a: { x: x + fullX, y: y - style.fullDividerRise }, b: { x: x + fullX, y: y + style.fullDividerRise }, role: "divider.full" },
          verb.place(x + verbLeft, y),
        ];
        if (comp) {
          const dx = x + compDx;
          if (comp.divider === "half") {
            ch.push({ kind: "seg", a: { x: dx, y: y - style.halfDividerRise }, b: { x: dx, y }, role: "divider.half" });
          } else {
            const len = style.halfDividerRise / Math.sin(style.leanLeftAngle);
            ch.push({ kind: "seg", a: { x: dx, y }, b: { x: dx - len * Math.cos(style.leanLeftAngle), y: y - len * Math.sin(style.leanLeftAngle) }, role: "divider.lean" });
          }
          ch.push(comp.measured.place(x + compLeft, y));
        }
        // Absolute phrases: a detached noun + participle diagram floating above the subject.
        let absTop = y;
        (clause.absolutes ?? []).forEach((abs, i) => {
          const am = measureHead(abs.head.text, abs.modifiers, `${idPrefix}/abs${i}`, "subject", abs.appositive?.text);
          const ay = absTop - am.below.bottom - style.em * 2.5;
          ch.push(am.place(x, ay));
          absTop = ay - SZ;
        });
        // Interjections / nominatives of address: a short horizontal line floating above the
        // subject, carrying the word, with no line connecting it to the rest of the diagram.
        (clause.detached ?? []).forEach((d, i) => {
          const lineW = w(d.text) + style.pad * 2;
          const ly = y - style.em * 3 - i * style.em * 1.8; // stack multiples upward
          ch.push({ kind: "seg", a: { x, y: ly }, b: { x: x + lineW, y: ly }, role: "baseline" });
          ch.push({ kind: "lbl", text: d.text, anchor: { x: x + style.pad, y: ly - 4 }, angle: 0, role: "word" });
        });
        return { id: idPrefix, role, children: ch, bounds: childrenBox(ch) };
      },
    };
  }

  const sentence: Sentence = "clauses" in input ? input : { clauses: [input], conjunctions: [] };

  // Single clause: unchanged (root id "c").
  if (sentence.clauses.length <= 1) {
    const root = measureClause(sentence.clauses[0] ?? (input as Clause), "c", "clause").place(START_X, BASE_Y);
    return { root, bounds: root.bounds };
  }

  // Compound sentence: stack the clause diagrams, joined by a dashed step with the conjunction.
  const nodes: SceneNode[] = [];
  const baselineYs: number[] = [];
  let y = BASE_Y - (sentence.clauses.length - 1) * style.em * 3.5;
  sentence.clauses.forEach((clause, i) => {
    const placed = measureClause(clause, `c${i}`, "clause").place(START_X, y);
    nodes.push(placed);
    baselineYs.push(y);
    y = placed.bounds.bottom + style.em * 3.5;
  });

  const extra: Prim[] = [];
  // Join the clauses at the left, clear of every clause's content (a wide subject must not be
  // crossed by the connector).
  const cx = Math.min(...nodes.map((n) => n.bounds.left)) - style.pad;
  for (let i = 0; i < nodes.length - 1; i++) {
    const conj = sentence.conjunctions[i];
    if (!conj) continue; // separate sentences (split input): just stack, no connector
    const y0 = baselineYs[i]!;
    const y1 = baselineYs[i + 1]!;
    extra.push({ kind: "seg", a: { x: cx, y: y0 }, b: { x: cx, y: y1 }, role: "connector.dotted" });
    extra.push({ kind: "lbl", text: conj.text, anchor: { x: cx + 4, y: (y0 + y1) / 2 }, angle: 0, role: "word" });
  }

  const children: Array<SceneNode | Prim> = [...nodes, ...extra];
  const root: SceneNode = { id: "s", role: "sentence", children, bounds: childrenBox(children) };
  return { root, bounds: root.bounds };
}

// Convenience: a Word -> single-word Nominal.
export const wordNominal = (word: Word): Nominal => ({ head: word, modifiers: [] });
