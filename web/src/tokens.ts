import { tokens } from "./tokens.generated.js";

/**
 * `DESIGN.md`, as CSS custom properties.
 *
 * The overlay lives in a shadow root, so these variables are scoped to it and cannot
 * leak into the host page or be overridden by it. Every rule in `overlay.css.ts`
 * reads a variable; nothing there holds a literal colour or number.
 */

type ColourName = keyof typeof tokens.color;

function rgba(name: ColourName, dark: boolean): string {
  const entry = tokens.color[name];
  const hex = dark ? entry.dark : entry.light;
  const alpha = dark ? entry.darkAlpha : entry.lightAlpha;
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return alpha === 1 ? `rgb(${r} ${g} ${b})` : `rgb(${r} ${g} ${b} / ${alpha})`;
}

/** `highlight.fill` becomes `--loupe-highlight-fill`. */
function variableName(name: string): string {
  return `--loupe-${name.replace(/\./g, "-")}`;
}

function palette(dark: boolean): string {
  return (Object.keys(tokens.color) as ColourName[])
    .map((name) => `  ${variableName(name)}: ${rgba(name, dark)};`)
    .join("\n");
}

/**
 * A colour a host supplies. Any CSS colour works - `#4338CA`, `oklch(...)`, or
 * `var(--brand)` to point straight at the host page's own variable.
 *
 * A bare string means both schemes. The overlay lives in a shadow root, so a host
 * page's stylesheet cannot reach in and this is the only way through.
 */
export type ThemeColour = string | { light: string; dark: string };

/**
 * What a host app can replace so the overlay stops looking like a visitor.
 *
 * Every field is optional: a host names what it has an opinion about and gets
 * Loupe's own look for the rest. **Deliberately not a styling API** - no
 * per-control overrides and no slots for custom markup. An overlay that can be
 * restyled arbitrarily becomes a UI framework, and the point is for this one to
 * disappear into its host.
 */
export interface Theme {
  /** The picked-element outline, badges and the focus ring. */
  accent?: ThemeColour;
  /** The wash inside a picked element. Follows `accent` unless it is given. */
  accentFill?: ThemeColour;
  surface?: ThemeColour;
  ink?: ThemeColour;
  inkSoft?: ThemeColour;
  line?: ThemeColour;
  action?: ThemeColour;
  cutaway?: ThemeColour;
  scrim?: ThemeColour;
  scrimModal?: ThemeColour;
  panelRadius?: number;
  controlRadius?: number;
  highlightRadius?: number;
  /** A CSS font stack. Sizes stay Loupe's, because they are hit targets too. */
  fontFamily?: string;
}

const COLOUR_VARIABLE: Record<string, string> = {
  accent: "--loupe-highlight",
  accentFill: "--loupe-highlight-fill",
  surface: "--loupe-surface",
  ink: "--loupe-ink",
  inkSoft: "--loupe-ink-soft",
  line: "--loupe-line",
  action: "--loupe-action",
  cutaway: "--loupe-cutaway",
  scrim: "--loupe-scrim",
  scrimModal: "--loupe-scrim-modal",
};

function scheme(colour: ThemeColour, dark: boolean): string {
  return typeof colour === "string" ? colour : (dark ? colour.dark : colour.light);
}

/**
 * The host's colours as variable declarations, for one scheme.
 *
 * `accent-fill` is derived from the accent when the host did not state one. A host
 * names one accent; working out the wash at the right alpha, in two schemes, is the
 * homework that makes a theming hook go unused. `color-mix` does it for any CSS
 * colour, including one the host passed as `var(--brand)`.
 */
function overrides(theme: Theme, dark: boolean): string {
  const lines: string[] = [];
  for (const [key, variable] of Object.entries(COLOUR_VARIABLE)) {
    const colour = theme[key as keyof Theme] as ThemeColour | undefined;
    if (colour !== undefined) lines.push(`  ${variable}: ${scheme(colour, dark)};`);
  }
  if (theme.accent !== undefined && theme.accentFill === undefined) {
    const percent = dark ? 14 : 10;
    lines.push(`  --loupe-highlight-fill: color-mix(in srgb, `
      + `${scheme(theme.accent, dark)} ${percent}%, transparent);`);
  }
  if (!dark) {
    if (theme.panelRadius !== undefined) lines.push(`  --loupe-radius-panel: ${theme.panelRadius}px;`);
    if (theme.controlRadius !== undefined) lines.push(`  --loupe-radius-control: ${theme.controlRadius}px;`);
    if (theme.highlightRadius !== undefined) lines.push(`  --loupe-radius-highlight: ${theme.highlightRadius}px;`);
    if (theme.fontFamily !== undefined) lines.push(`  font-family: ${theme.fontFamily};`);
  }
  return lines.join("\n");
}

export function cssVariables(theme: Theme = {}): string {
  const scale = [
    ...Object.entries(tokens.space).map(([k, v]) => `  --loupe-space-${k}: ${v}px;`),
    ...Object.entries(tokens.radius).map(([k, v]) => `  --loupe-radius-${k}: ${v}px;`),
    ...Object.entries(tokens.stroke).map(([k, v]) => `  --loupe-stroke-${k}: ${v}px;`),
    ...Object.entries(tokens.motion).map(([k, v]) => `  --loupe-motion-${k}: ${v}ms;`),
    ...Object.entries(tokens.hit).map(([k, v]) => `  --loupe-hit-${k}: ${v}px;`),
    `  --loupe-elevation-panel: 0 ${tokens.elevation.panelOffsetY}px ` +
      `${tokens.elevation.panelRadius}px rgb(0 0 0 / ${tokens.elevation.panelOpacity});`,
  ].join("\n");

  // Light is the base and dark is the override, so a host page that never declares
  // a scheme still gets a complete palette. A host's own values come last in each
  // block, so they win without anything here having to know what they are.
  return `:host {
${palette(false)}
${scale}
${overrides(theme, false)}
}

@media (prefers-color-scheme: dark) {
  :host {
${palette(true)}
${overrides(theme, true)}
  }
}`;
}

export const tagColour: Record<string, string> = Object.fromEntries(
  Object.entries(tokens.tag).map(([tag, colour]) => [tag, `var(${variableName(colour)})`]),
);

export { tokens };
