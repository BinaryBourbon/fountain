// Theme — role -> appearance. Same geometry, different looks by swapping one object.
// Strictly separate from LayoutStyle: nothing here may change coordinates.

import type { Role } from "./scene.js";

export type StrokeSpec = {
  color: string;
  weight: number;
  dash?: number[];
  cap?: "butt" | "round" | "square";
};

export type FontSpec = {
  family: string;
  size: number; // px
  style?: "normal" | "italic";
  weight?: number;
};

export type Override = Partial<StrokeSpec> & { opacity?: number };

export type EmphasisState = "hover" | "active" | "muted";

export interface Theme {
  stroke(role: Role): StrokeSpec;
  font(role: Role): FontSpec;
  emphasis(role: Role, state: EmphasisState): Override;
}

// Geometric style — feeds layout(), changes coordinates. Kept apart from Theme on purpose.
export type LayoutStyle = {
  em: number; // base unit driving spacing
  slantAngle: number; // theta, radians from horizontal
  dividerGap: number; // min horizontal gap at a divider
  fullDividerRise: number; // how far the full vertical crosses above/below the baseline
  halfDividerRise: number; // verb|object half-divider height (sits on baseline)
  leanLeftAngle: number; // angle of the lean-left complement divider
  minSlantSpacing: number; // min x-distance between two slants under one head
  pad: number;
};

// A minimal, clean-minimal Theme — proves the role->appearance seam. Phase 4 adds variants.
export const defaultTheme: Theme = {
  stroke(role: Role): StrokeSpec {
    switch (role) {
      case "baseline":
      case "rail":
        return { color: "#2b2b2b", weight: 1.8, cap: "round" };
      case "divider.full":
      case "divider.half":
      case "divider.lean":
        return { color: "#2b2b2b", weight: 1.4, cap: "round" };
      case "slant":
        return { color: "#3a3a3a", weight: 1.2, cap: "round" };
      case "connector.dotted":
        return { color: "#6a6a6a", weight: 1.1, dash: [3, 3], cap: "butt" };
      default:
        return { color: "#2b2b2b", weight: 1.2 };
    }
  },
  font(_role: Role): FontSpec {
    return { family: "Tinos, Georgia, 'Times New Roman', serif", size: 16 }; // pinned: matches test metrics
  },
  emphasis(_role: Role, state: EmphasisState): Override {
    if (state === "muted") return { opacity: 0.35 };
    if (state === "hover") return { color: "#1769aa" };
    return { color: "#0b3d91" };
  },
};

// A second, visually distinct Theme over IDENTICAL geometry — proves the role->appearance
// seam and the LayoutStyle/RenderStyle split (this changes appearance, never coordinates).
export const blueprintTheme: Theme = {
  stroke(role: Role): StrokeSpec {
    switch (role) {
      case "baseline":
      case "rail":
        return { color: "#cfe8ff", weight: 2, cap: "round" };
      case "slant":
        return { color: "#9ecbff", weight: 1.3, cap: "round" };
      case "connector.dotted":
        return { color: "#7fb0e8", weight: 1.1, dash: [2, 4], cap: "butt" };
      case "fork":
        return { color: "#9ecbff", weight: 1.3, cap: "round" };
      default:
        return { color: "#dbeeff", weight: 1.5, cap: "round" };
    }
  },
  font(_role: Role): FontSpec {
    return { family: "ui-monospace, 'SF Mono', Menlo, monospace", size: 15 };
  },
  emphasis(_role: Role, state: EmphasisState): Override {
    if (state === "muted") return { opacity: 0.4 };
    return { color: "#ffd36b" };
  },
};

export const defaultLayoutStyle: LayoutStyle = {
  em: 16,
  slantAngle: Math.PI / 3, // 60deg
  dividerGap: 18,
  fullDividerRise: 14,
  halfDividerRise: 12,
  leanLeftAngle: Math.PI / 3,
  minSlantSpacing: 14,
  pad: 8,
};
