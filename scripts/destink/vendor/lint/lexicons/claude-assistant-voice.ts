// The chat register leaking into prose (issue #34) — reflexive validation and customer-service
// phrases from Claude's assistant voice, showing up in a written document instead of a live
// back-and-forth with a user. Wired through the claude-lexicon factory (rules/claude-lexicon.ts):
// ONE hit already fires, visibly, per that tier's inverted severity philosophy — see that file's
// header for why this lexicon does NOT get the generic lexical tier's below-threshold step-down.
//
// Severity shape:
//   - "you're absolutely right" / "you are absolutely right" / "you're absolutely correct" are
//     pinned at "high" — the canonical Claudeism (anthropics/claude-code#3382, an HN front-page
//     thread, a dedicated joke site). Fires even when the user made no factual claim; unmistakable,
//     never used by accident.
//   - "production-ready" is pinned at "low" — a real, dev-legit phrase most of the time, but a
//     known Claude-Code overclaim tell (premature "it's production-ready!" after one green test
//     run) worth flagging quietly rather than loudly.
//   - Everything else rides the lexicon's defaultSeverity ("medium") and escalates to "high" once
//     the document racks up densityThreshold (3) hits from this lexicon — escalation only, per
//     rules/claude-lexicon.ts; a lone hit never gets stepped DOWN the way the generic lexical tier
//     would.
import type { Lexicon } from "./types.js";

export const claudeAssistantVoice: Lexicon = {
  id: "claude-assistant-voice",
  name: "Claude assistant voice",
  defaultSeverity: "medium",
  densityThreshold: 3,
  entries: [
    { match: ["you're", "absolutely", "right"], severity: "high" },
    { match: ["you", "are", "absolutely", "right"], severity: "high" },
    { match: ["you're", "absolutely", "correct"], severity: "high" },
    { match: ["great", "question"] },
    { match: ["excellent", "question"] },
    { match: ["that's", "a", "great", "point"] },
    { match: ["great", "catch"] },
    { match: ["i", "appreciate", "your", "patience"] },
    { match: ["i", "apologize", "for", "the", "confusion"] },
    { match: ["happy", "to", "elaborate"] },
    { match: ["feel", "free", "to"] },
    { match: ["would", "you", "like", "me", "to"] },
    { match: ["a", "good", "starting", "point"] },
    { match: ["a", "solid", "starting", "point"] },
    { match: ["a", "great", "starting", "point"] },
    { match: ["there's", "no", "one-size-fits-all"] },
    { match: ["your", "mileage", "may", "vary"] },
    { match: ["reasonable", "people", "can", "disagree"] },
    {
      match: "production-ready",
      severity: "low",
      note: "dev-legit most of the time; flagged low as a known Claude-Code overclaim tell, not an accusation",
    },
    { match: ["this", "matters", "because"] },
  ],
};
