import type { ElementRef, PathPoint, Rect } from "./types.js";

/**
 * Turns a point someone clicked into the element they meant.
 *
 * `document.elementFromPoint` returns the deepest element under the pointer, which
 * on a real page is almost always a `<span>` inside the thing you were pointing at.
 * If the reference and the crop describe that inner fragment, every downstream step
 * reasons about the wrong element. So the picker climbs to the nearest *meaningful*
 * ancestor, exactly as the Swift SDK does.
 */

/** An ancestor covering most of the viewport is a container, not the thing you meant. */
/**
 * Deliberately looser than the Swift SDK's one third.
 *
 * There, the walk routinely lands on a SwiftUI layout container that no `<div>`
 * corresponds to, because SwiftUI backs almost nothing with a real view. Here every
 * element is real and the climb stops at a named or interactive one far more often,
 * so a `<section>` covering half the viewport is usually a section somebody meant.
 * Same rule, different platform, different number - not an oversight.
 */
export const MAX_VIEWPORT_AREA_FRACTION = 0.8;

const INTERACTIVE_TAGS = new Set([
  "a", "button", "input", "select", "textarea", "summary", "option",
]);

const INTERACTIVE_ROLES = new Set([
  "button", "link", "checkbox", "radio", "switch", "tab", "menuitem",
  "option", "textbox", "combobox", "slider", "searchbox",
]);

/** The names an app gives an element on purpose, best first. */
const NAME_ATTRIBUTES = [
  "data-loupe-id", "data-testid", "data-test-id", "data-test", "data-cy", "id",
];

/**
 * Meaningful means: the app named it, or a person can interact with it.
 *
 * `aria-label` is deliberately *not* on its own enough. A screen-reader label on a
 * decorative icon is common, and stopping there reproduces the exact bug the climb
 * exists to avoid - the AppKit version of which was treating a static label as a
 * control because `NSTextField` subclasses `NSControl`.
 */
export function isMeaningful(element: Element): boolean {
  if (namedBy(element)) return true;

  const tag = element.tagName.toLowerCase();
  if (INTERACTIVE_TAGS.has(tag)) return true;

  const role = element.getAttribute("role");
  if (role && INTERACTIVE_ROLES.has(role)) return true;

  if (element.hasAttribute("contenteditable")) return true;
  // A negative tabindex means "focusable by script", not "interactive to a person".
  const tabindex = element.getAttribute("tabindex");
  if (tabindex !== null && Number(tabindex) >= 0) return true;

  return false;
}

export function namedBy(element: Element): string | undefined {
  for (const attribute of NAME_ATTRIBUTES) {
    const value = element.getAttribute(attribute);
    if (value && value.trim()) return value.trim();
  }
  return undefined;
}

export function meaningfulAncestor(element: Element, viewportArea: number): Element {
  let current = element;
  while (!isMeaningful(current)) {
    const parent = current.parentElement;
    if (!parent) break;
    if (viewportArea > 0 && area(parent) / viewportArea > MAX_VIEWPORT_AREA_FRACTION) break;
    current = parent;
  }
  return current;
}

/**
 * The element under a viewport point, climbed to the one a person would name.
 *
 * `ignore` is checked against the **raw** hit, before the climb. It has to be:
 * `elementFromPoint` retargets anything inside a shadow root to its host, so a point
 * over the overlay's own tray comes back as the overlay element - which is not
 * meaningful, so the climb would walk straight out of it and hand back `<html>`.
 * Checked after the climb, the caller would see a plausible-looking element and
 * capture a picture of the entire page.
 */
export function pick(
  x: number,
  y: number,
  doc: Document = document,
  ignore?: (element: Element) => boolean,
): Element | null {
  const hit = doc.elementFromPoint(x, y);
  if (!hit) return null;
  if (ignore?.(hit)) return null;
  const view = doc.defaultView;
  const viewportArea = view ? view.innerWidth * view.innerHeight : 0;
  const target = meaningfulAncestor(hit, viewportArea);
  return isBackdrop(target, viewportArea) ? null : target;
}

/**
 * Whether the pick landed on nothing.
 *
 * The area guard in the climb only fires while climbing, so it misses the case that
 * matters most: pointing at empty page background, where the hit is already `<body>`
 * and there is nothing to climb from. Found on iPad first, and the same hole was
 * here. Refused only when the element is *also* unnamed - a full-bleed hero or map
 * the page has named is a real element, and someone pointing at it means it.
 */
export function isBackdrop(element: Element, viewportArea: number): boolean {
  if (viewportArea <= 0) return false;
  if (area(element) / viewportArea <= MAX_VIEWPORT_AREA_FRACTION) return false;
  return !isMeaningful(element);
}

/** The smallest drag worth treating as a region rather than a slipped click. */
export const MINIMUM_REGION_SIZE = 12;

/**
 * A dragged rectangle, clipped to the viewport.
 *
 * No screenshot: the web capture works by cloning an element into an SVG
 * `foreignObject`, and a region has no element to clone. `bounds` is what a region
 * has to say, and `docs/bundle-format.md` already treats every field but bounds as
 * best-effort.
 */
export function regionRef(rect: Rect, viewport: { width: number; height: number }): ElementRef | null {
  const left = Math.max(0, Math.min(rect.x, rect.x + rect.width));
  const top = Math.max(0, Math.min(rect.y, rect.y + rect.height));
  const right = Math.min(viewport.width, Math.max(rect.x, rect.x + rect.width));
  const bottom = Math.min(viewport.height, Math.max(rect.y, rect.y + rect.height));

  const width = right - left;
  const height = bottom - top;
  if (width < MINIMUM_REGION_SIZE || height < MINIMUM_REGION_SIZE) return null;

  return { kind: "region", bounds: { x: left, y: top, width, height } };
}

/**
 * The smallest area a shape can enclose and still mean something, in square CSS
 * pixels. A 20-pixel square.
 *
 * **Area, not the bounding box, and that distinction is the whole rule.** A lasso
 * says "the things inside this". A straight swipe has a bounding box hundreds of
 * pixels wide and encloses nothing at all, so by any box measure it is a fine shape
 * and by the only measure that matters it is empty.
 */
export const LEAST_USEFUL_AREA = 20 * 20;

/**
 * Ramer-Douglas-Peucker, in CSS pixels.
 *
 * A pointer emits an event per frame, so a shape around one card arrives as several
 * hundred points, nearly all of which sit on top of each other. At two pixels of
 * tolerance the simplified shape is indistinguishable on screen from the raw one.
 */
export function simplifyPath(points: PathPoint[], tolerance = 2): PathPoint[] {
  if (points.length <= 2 || tolerance <= 0) return points;

  const first = points[0];
  const last = points[points.length - 1];
  // `noUncheckedIndexedAccess`: the length check above does not narrow an index, and
  // a silent `!` here is exactly the sort of assertion this project keeps finding
  // afterwards.
  if (!first || !last) return points;

  let furthest = 0;
  let distance = 0;
  for (let i = 1; i < points.length - 1; i += 1) {
    const point = points[i];
    if (!point) continue;
    const candidate = perpendicular(point, first, last);
    if (candidate > distance) {
      distance = candidate;
      furthest = i;
    }
  }
  if (distance <= tolerance) return [first, last];

  const left = simplifyPath(points.slice(0, furthest + 1), tolerance);
  const right = simplifyPath(points.slice(furthest), tolerance);
  // `furthest` ends the left run and starts the right, so one copy of it is dropped.
  return [...left.slice(0, -1), ...right];
}

/** The smallest rectangle holding every point. This is what `bounds` carries. */
export function pathBounds(points: PathPoint[]): Rect {
  const first = points[0];
  if (!first) return { x: 0, y: 0, width: 0, height: 0 };
  let [minX, minY] = first;
  let [maxX, maxY] = first;
  for (const [x, y] of points) {
    minX = Math.min(minX, x);
    maxX = Math.max(maxX, x);
    minY = Math.min(minY, y);
    maxY = Math.max(maxY, y);
  }
  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
}

/** The area the closed shape encloses, by the shoelace formula. Always positive. */
export function pathArea(points: PathPoint[]): number {
  if (points.length < 3) return 0;
  let sum = 0;
  for (let i = 0, j = points.length - 1; i < points.length; j = i, i += 1) {
    const a = points[i];
    const b = points[j];
    if (!a || !b) continue;
    sum += (b[0] + a[0]) * (b[1] - a[1]);
  }
  return Math.abs(sum) / 2;
}

/**
 * A shape, or a pointer that slipped.
 *
 * The caller falls back to picking whatever is under the first point, which is what
 * somebody almost certainly meant - rather than refusing, which loses the gesture
 * entirely and explains nothing.
 */
export function isUsablePath(points: PathPoint[]): boolean {
  return points.length >= 3 && pathArea(points) >= LEAST_USEFUL_AREA;
}

/**
 * A drawn shape, thinned and clipped to the viewport.
 *
 * **No screenshot, for the same reason a region has none.** The web capture clones an
 * element into an SVG `foreignObject`, and a shape has no element to clone. It is
 * worse than that for a path: even a bounding-box crop taken some other way would be
 * a rectangle, which is the exact thing the person went out of their way not to say.
 * `bounds` plus `path` is what a shape has to offer here, and `docs/bundle-format.md`
 * already treats every field but bounds as best-effort.
 */
export function pathRef(
  drawn: PathPoint[],
  viewport: { width: number; height: number },
): ElementRef | null {
  const clipped: PathPoint[] = drawn.map(([x, y]) => [
    Math.max(0, Math.min(viewport.width, x)),
    Math.max(0, Math.min(viewport.height, y)),
  ]);
  const points = simplifyPath(clipped);
  if (!isUsablePath(points)) return null;
  return { kind: "path", bounds: pathBounds(points), path: points };
}

function perpendicular(point: PathPoint, start: PathPoint, end: PathPoint): number {
  const dx = end[0] - start[0];
  const dy = end[1] - start[1];
  // A closed shape starts and ends in the same place, so the line through its ends
  // has no length and the formula below divides by zero. That is the normal case
  // here, not an edge case.
  if (dx === 0 && dy === 0) {
    return Math.hypot(point[0] - start[0], point[1] - start[1]);
  }
  const twiceArea = Math.abs(
    dy * point[0] - dx * point[1] + end[0] * start[1] - end[1] * start[0],
  );
  return twiceArea / Math.hypot(dx, dy);
}

export function elementRef(element: Element): ElementRef {
  const ref: ElementRef = {
    kind: "view",
    className: element.tagName.toLowerCase(),
    selector: cssSelector(element),
    bounds: bounds(element),
  };
  const name = namedBy(element);
  if (name) ref.accessibilityID = name;
  const label = labelOf(element);
  if (label) ref.label = label;
  return ref;
}

export function bounds(element: Element): Rect {
  const box = element.getBoundingClientRect();
  return { x: box.left, y: box.top, width: box.width, height: box.height };
}

/**
 * What a person would call this element. The accessible name first, then its own
 * text, trimmed - a whole paragraph in a bundle field helps nobody.
 */
export function labelOf(element: Element): string | undefined {
  const aria = element.getAttribute("aria-label");
  if (aria && aria.trim()) return aria.trim();

  // Checked by tag name rather than `instanceof`. An element inside an iframe comes
  // from another realm, where `instanceof HTMLInputElement` is false against this
  // window's constructor - and a staging app with an embedded preview is exactly
  // where someone would want to annotate.
  const tag = element.tagName.toLowerCase();
  if (tag === "input" || tag === "textarea") {
    const field = element as HTMLInputElement;
    return field.placeholder || field.value || undefined;
  }
  if (tag === "img") {
    const alt = element.getAttribute("alt");
    if (alt) return alt;
  }

  const text = (element.textContent ?? "").replace(/\s+/g, " ").trim();
  if (!text) return undefined;
  return text.length > 80 ? `${text.slice(0, 79)}…` : text;
}

/**
 * A selector short enough to read and specific enough to find the element again.
 *
 * It stops the moment it is unique, rather than always walking to `<body>`: a
 * fourteen-step `div > div > div` chain is not something anyone can act on, and it
 * breaks on the next re-render anyway.
 */
export function cssSelector(element: Element, doc: Document = element.ownerDocument): string {
  const steps: string[] = [];
  let current: Element | null = element;

  while (current && current.nodeType === 1 && steps.length < 5) {
    const step = selectorStep(current);
    steps.unshift(step);

    const candidate = steps.join(" > ");
    if (isUnique(candidate, doc)) return candidate;
    if (step.startsWith("#")) return candidate;

    current = current.parentElement;
  }
  return steps.join(" > ");
}

function selectorStep(element: Element): string {
  const id = element.getAttribute("id");
  if (id && isSafeIdentifier(id)) return `#${id}`;

  for (const attribute of ["data-loupe-id", "data-testid", "data-test-id", "data-cy"]) {
    const value = element.getAttribute(attribute);
    if (value) return `${element.tagName.toLowerCase()}[${attribute}="${cssEscape(value)}"]`;
  }

  const tag = element.tagName.toLowerCase();
  const parent = element.parentElement;
  if (!parent) return tag;

  const siblings = [...parent.children].filter((c) => c.tagName === element.tagName);
  if (siblings.length === 1) return tag;
  return `${tag}:nth-of-type(${siblings.indexOf(element) + 1})`;
}

function isUnique(selector: string, doc: Document): boolean {
  try {
    return doc.querySelectorAll(selector).length === 1;
  } catch {
    return false;
  }
}

/** Framework-generated ids are full of characters a bare `#id` cannot carry. */
function isSafeIdentifier(value: string): boolean {
  return /^[A-Za-z_][\w-]*$/.test(value);
}

function cssEscape(value: string): string {
  return value.replace(/["\\]/g, "\\$&");
}

function area(element: Element): number {
  const box = element.getBoundingClientRect();
  return box.width * box.height;
}
