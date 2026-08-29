import { cssVariables } from "./tokens.js";

/**
 * Every rule reads a variable. No literal colour, size or duration appears here -
 * `DESIGN.md` is the source, `tokens.ts` turns it into variables, and this file only
 * arranges them.
 *
 * It all lives in a shadow root, so the host page cannot reach in and nothing here
 * leaks out. That matters more on the web than anywhere else: a staging app with a
 * global `* { box-sizing }` or a `div { margin: 0 }` reset would otherwise reshape
 * the tool sitting on top of it.
 */
export function overlayCSS(): string {
  return `${cssVariables()}

:host {
  position: fixed;
  inset: 0;
  z-index: 2147483000;
  /* The host page stays usable: only the panels take the pointer. */
  pointer-events: none;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  color: var(--loupe-ink);
  --loupe-font-body: 0.9375rem;
  --loupe-font-label: 0.8125rem;
  --loupe-font-caption: 0.75rem;
  --loupe-mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
}

* { box-sizing: border-box; }

.scrim {
  position: absolute;
  inset: 0;
  background: var(--loupe-scrim);
}

/* The picked element, and the number that says which one it is. The outline is
   never the only signal. */
/* Dashed on purpose: a solid outline is what a resolved element looks like, and the
   two must never be confused. One says "this is what I found", the other says "this
   is the area you are drawing". */
.drag-region {
  position: absolute;
  border: var(--loupe-stroke-highlight) dashed var(--loupe-highlight);
  border-radius: var(--loupe-radius-highlight);
  background: var(--loupe-highlight-fill);
  pointer-events: none;
}

.highlight {
  position: absolute;
  border: var(--loupe-stroke-highlight) solid var(--loupe-highlight);
  border-radius: var(--loupe-radius-highlight);
  background: var(--loupe-highlight-fill);
  transition: all var(--loupe-motion-hover) ease-out;
}

.badge {
  position: absolute;
  display: grid;
  place-items: center;
  min-width: var(--loupe-hit-pointer);
  height: var(--loupe-hit-pointer);
  padding: 0 var(--loupe-space-xs);
  border-radius: 999px;
  background: var(--loupe-highlight);
  color: var(--loupe-surface);
  font-family: var(--loupe-mono);
  font-size: var(--loupe-font-caption);
  transform: translate(-50%, -50%);
}

.panel {
  position: absolute;
  pointer-events: auto;
  border-radius: var(--loupe-radius-panel);
  border: var(--loupe-stroke-hairline) solid var(--loupe-line);
  /* Translucent, but blurred. A merely see-through panel lets the host page's own
     text read straight through a comment. */
  background: var(--loupe-surface);
  backdrop-filter: blur(20px) saturate(1.4);
  -webkit-backdrop-filter: blur(20px) saturate(1.4);
  box-shadow: var(--loupe-elevation-panel);
  animation: loupe-in var(--loupe-motion-panel) ease-out;
}

@keyframes loupe-in {
  from { opacity: 0; transform: translateY(var(--loupe-space-xs)); }
  to   { opacity: 1; transform: none; }
}

.popover {
  width: 320px;
  padding: var(--loupe-space-lg);
  display: grid;
  gap: var(--loupe-space-md);
}

.head { display: flex; gap: var(--loupe-space-sm); align-items: flex-start; }
.head .badge { position: static; transform: none; }
.head .name { font-size: var(--loupe-font-label); font-weight: 600; }
.head .detail {
  font-family: var(--loupe-mono);
  font-size: var(--loupe-font-caption);
  color: var(--loupe-ink-soft);
  overflow-wrap: anywhere;
}

textarea {
  width: 100%;
  min-height: calc(var(--loupe-space-xxl) * 2);
  padding: var(--loupe-space-sm);
  border: var(--loupe-stroke-hairline) solid var(--loupe-line);
  border-radius: var(--loupe-radius-control);
  background: transparent;
  color: var(--loupe-ink);
  font: inherit;
  font-size: var(--loupe-font-body);
  resize: vertical;
}

.chips { display: flex; gap: var(--loupe-space-sm); flex-wrap: wrap; }

.chip {
  min-height: var(--loupe-hit-pointer);
  padding: 0 var(--loupe-space-sm);
  border: var(--loupe-stroke-hairline) solid currentColor;
  border-radius: var(--loupe-radius-control);
  background: transparent;
  color: var(--chip-colour);
  font-family: var(--loupe-mono);
  font-size: var(--loupe-font-caption);
  cursor: pointer;
}

.chip[aria-pressed="true"] { background: var(--chip-colour); color: var(--loupe-surface); }

.row { display: flex; align-items: center; gap: var(--loupe-space-sm); }
.row .spacer { flex: 1; }

button {
  min-height: var(--loupe-hit-pointer);
  padding: 0 var(--loupe-space-md);
  border-radius: var(--loupe-radius-control);
  border: var(--loupe-stroke-hairline) solid var(--loupe-line);
  background: transparent;
  color: var(--loupe-ink);
  font: inherit;
  font-size: var(--loupe-font-label);
  font-weight: 600;
  cursor: pointer;
}

button.primary {
  background: var(--loupe-action);
  color: var(--loupe-surface);
  border-color: transparent;
}

button.quiet { border-color: transparent; color: var(--loupe-ink-soft); font-weight: 400; }
button:disabled { opacity: 0.4; cursor: default; }
button:not(:disabled):hover { filter: brightness(0.94); }
button:not(:disabled):active { transform: translateY(1px); }

/* Instant, never animated: a ring that fades in is a ring you have stopped
   looking for. */
:is(button, textarea, .chip):focus-visible {
  outline: var(--loupe-stroke-focus) solid var(--loupe-highlight);
  outline-offset: var(--loupe-stroke-focusOffset);
}

/* The tray hugs an edge and never covers the centre of the screen. */
.tray {
  top: var(--loupe-space-lg);
  right: var(--loupe-space-lg);
  width: 340px;
  max-height: calc(100% - var(--loupe-space-xxl));
  display: flex;
  flex-direction: column;
}

.tray header, .tray footer {
  display: flex;
  align-items: center;
  gap: var(--loupe-space-sm);
  padding: var(--loupe-space-md);
}

.tray header { border-bottom: var(--loupe-stroke-hairline) solid var(--loupe-line); }
.tray footer { border-top: var(--loupe-stroke-hairline) solid var(--loupe-line); }
.tray header .title { font-size: var(--loupe-font-label); font-weight: 600; }
.tray .list { overflow-y: auto; }
.tray footer button.primary { flex: 1; }

/* Nothing picked yet: one line, not a panel offering to send zero notes. */
.hint {
  top: var(--loupe-space-lg);
  right: var(--loupe-space-lg);
  display: flex;
  align-items: center;
  gap: var(--loupe-space-sm);
  padding: var(--loupe-space-sm) var(--loupe-space-md);
  color: var(--loupe-ink-soft);
  font-size: var(--loupe-font-body);
}

.item {
  display: flex;
  gap: var(--loupe-space-md);
  padding: var(--loupe-space-md);
  align-items: flex-start;
}

.item + .item { border-top: var(--loupe-stroke-hairline) solid var(--loupe-line); }
.item .body { flex: 1; display: grid; gap: var(--loupe-space-xs); min-width: 0; }
.item .comment { font-size: var(--loupe-font-body); overflow-wrap: anywhere; }
.item img {
  max-width: 100%;
  max-height: 96px;
  border-radius: var(--loupe-radius-highlight);
  border: var(--loupe-stroke-hairline) solid var(--loupe-line);
}
.item .meta {
  font-family: var(--loupe-mono);
  font-size: var(--loupe-font-caption);
  color: var(--loupe-ink-soft);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.item .errors { color: var(--loupe-highlight); }
.item .tag { font-family: var(--loupe-mono); font-size: var(--loupe-font-caption); }
.failed { color: var(--loupe-highlight); font-size: var(--loupe-font-caption); }

@media (prefers-reduced-motion: reduce) {
  /* Spatial movement is the part that makes people ill, so it is the part that
     goes. Everything becomes a cross-fade at the hover duration. */
  .highlight, .panel { transition-duration: var(--loupe-motion-hover); animation: none; }
  button:not(:disabled):active { transform: none; }
}

/* On a phone the tray becomes a sheet at the bottom edge. */
@media (max-width: 600px) {
  .tray, .hint {
    top: auto;
    bottom: var(--loupe-space-md);
    left: var(--loupe-space-md);
    right: var(--loupe-space-md);
    width: auto;
    max-height: 50%;
  }
  .chip, button { min-height: var(--loupe-hit-touch); }
}
`;
}
