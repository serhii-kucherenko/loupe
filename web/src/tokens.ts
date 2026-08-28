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

export function cssVariables(): string {
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
  // a scheme still gets a complete palette.
  return `:host {
${palette(false)}
${scale}
}

@media (prefers-color-scheme: dark) {
  :host {
${palette(true)}
  }
}`;
}

export const tagColour: Record<string, string> = Object.fromEntries(
  Object.entries(tokens.tag).map(([tag, colour]) => [tag, `var(${variableName(colour)})`]),
);

export { tokens };
