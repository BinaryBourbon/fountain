/**
 * Fountain Tailwind configuration.
 *
 * Used two ways:
 *   1. Inline as window.tailwind.config in root.html.heex (CDN mode)
 *   2. As the build config when a Node/bundler pipeline is added later
 *
 * All colour values are CSS custom property references defined in
 * assets/css/tokens.css, so a single token change covers both light and
 * dark mode without any Tailwind rebuild.
 */
module.exports = {
  darkMode: ["selector", '[data-theme="dark"]'],
  theme: {
    extend: {
      colors: {
        brand: {
          DEFAULT: "var(--color-brand)",
          hover: "var(--color-brand-hover)",
        },
        surface: {
          0: "var(--color-bg-0)",
          1: "var(--color-bg-1)",
          2: "var(--color-bg-2)",
          3: "var(--color-bg-3)",
        },
        "ft-border": {
          DEFAULT: "var(--color-border)",
          strong: "var(--color-border-strong)",
        },
        "ft-text": {
          primary:   "var(--color-text-primary)",
          secondary: "var(--color-text-secondary)",
          muted:     "var(--color-text-muted)",
        },
        "ft-success": {
          DEFAULT: "var(--color-success)",
          bg:      "var(--color-success-bg)",
          text:    "var(--color-success-text)",
        },
        "ft-warning": {
          DEFAULT: "var(--color-warning)",
          bg:      "var(--color-warning-bg)",
          text:    "var(--color-warning-text)",
        },
        "ft-error": {
          DEFAULT: "var(--color-error)",
          bg:      "var(--color-error-bg)",
          text:    "var(--color-error-text)",
        },
        "ft-info": {
          DEFAULT: "var(--color-info)",
          bg:      "var(--color-info-bg)",
          text:    "var(--color-info-text)",
        },
        "ft-code": {
          bg:   "var(--color-code-bg)",
          text: "var(--color-code-text)",
        },
      },
    },
  },
  plugins: [],
};
