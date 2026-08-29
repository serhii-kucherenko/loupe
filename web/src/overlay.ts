import type {
  Annotation, AnnotationTag, ElementRef, PathPoint, Rect,
} from "./types.js";
import { uuid } from "./types.js";

/** Which gesture is meant. Mirrors `PickTool` in the Swift SDK, name for name. */
export type PickTool = "point" | "box" | "draw";
import type { AnnotationSession } from "./session.js";
import type { QueuedTransport } from "./transport.js";
import {
  MINIMUM_REGION_SIZE, elementRef, pathRef, pick as pickElement, regionRef,
} from "./picker.js";

/**
 * Where a pick is on screen: the element's live rectangle, or the region's own.
 *
 * Live for an element, because the page can scroll between picking and drawing the
 * popover. A region has no element, and its bounds are already viewport coordinates.
 */
function boxOf(pick: PendingPick): DOMRect {
  if (pick.element) return pick.element.getBoundingClientRect();
  const { x, y, width, height } = pick.ref.bounds;
  return {
    x, y, width, height,
    left: x, top: y, right: x + width, bottom: y + height,
    toJSON: () => ({}),
  } as DOMRect;
}

/** The rectangle between two points, however it was dragged. */
function between(a: { x: number; y: number }, b: { x: number; y: number }): Rect {
  return {
    x: Math.min(a.x, b.x),
    y: Math.min(a.y, b.y),
    width: Math.abs(a.x - b.x),
    height: Math.abs(a.y - b.y),
  };
}
import type { LogRecorder, NetworkRecorder } from "./recorder.js";
import { screenshotPNG } from "./capture.js";
import { overlayCSS } from "./overlay.css.js";
import { tagColour } from "./tokens.js";

export interface PendingPick {
  /** Absent for a region: nothing on the page corresponds to it. */
  element?: Element;
  ref: ElementRef;
  screenshotPNG?: string;
  index: number;
}

/**
 * What the overlay is doing, and therefore whether the page underneath is usable.
 *
 * The one that carries the product is `browsing`. You have to be able to navigate
 * to a second screen with the tray still full, so once a comment is saved the
 * overlay stops intercepting clicks.
 */
export type OverlayMode =
  | { kind: "off" }
  | { kind: "picking"; hover?: Element }
  | { kind: "commenting"; pick: PendingPick }
  | { kind: "browsing" };

export type SendState =
  | { kind: "idle" }
  | { kind: "sending" }
  | { kind: "failed"; why: string }
  | { kind: "sent"; count: number };

export function swallowsInput(mode: OverlayMode): boolean {
  return mode.kind === "picking" || mode.kind === "commenting";
}

export interface OverlayOptions {
  queue?: QueuedTransport;
  /** The requests and log lines to attach to each pick. */
  network?: NetworkRecorder;
  logs?: LogRecorder;
  screen?: () => string;
  /** Off in tests and anywhere a canvas is not worth the milliseconds. */
  captureScreenshots?: boolean;
}

/**
 * The overlay, in a shadow root above the host page.
 *
 * The web makes pass-through easy in a way AppKit does not: the host element is
 * `pointer-events: none` and only the panels turn it back on, so the page underneath
 * keeps every click the overlay is not using. `elementFromPoint` skips the host for
 * the same reason, which is what lets the picker see through it.
 */
export class Overlay {
  private readonly session: AnnotationSession;
  private readonly options: OverlayOptions;
  private readonly doc: Document;
  private readonly view: Window & typeof globalThis;

  private host: HTMLElement;
  private root: ShadowRoot;
  private mode: OverlayMode = { kind: "off" };
  private sendState: SendState = { kind: "idle" };
  private draft = { comment: "", tag: undefined as AnnotationTag | undefined };
  /// The popover is rebuilt on every render, so "focus the field" has to mean the
  /// first time it opens. Focusing on each render throws a keyboard user out of the
  /// tag chips the moment they choose one.
  private popoverIsNew = true;
  private listeners: Array<() => void> = [];

  constructor(session: AnnotationSession, view: Window & typeof globalThis,
              options: OverlayOptions = {}) {
    this.session = session;
    this.view = view;
    this.doc = view.document;
    this.options = options;

    this.host = this.doc.createElement("loupe-overlay");
    this.root = this.host.attachShadow({ mode: "open" });
    const style = this.doc.createElement("style");
    style.textContent = overlayCSS();
    this.root.append(style);
    this.doc.body.append(this.host);

    this.session.onChange = () => this.render();
    this.installShortcuts();
    this.render();
  }

  // MARK: - Mode

  get currentMode(): OverlayMode { return this.mode; }
  get pendingCount(): number { return this.options.queue?.pendingCount ?? 0; }

  begin(): void {
    if (this.mode.kind !== "off") return;
    this.setMode({ kind: "picking" });
  }

  end(): void {
    this.setMode({ kind: "off" });
  }

  /** One key, one meaning: am I annotating right now. */
  toggle(): void {
    this.mode.kind === "off" ? this.begin() : this.end();
  }

  async pickAt(x: number, y: number): Promise<void> {
    this.resolveDraftAndResumePicking();
    if (this.mode.kind !== "picking") return;
    const element = pickElement(x, y, this.doc, (hit) => this.isOurs(hit));
    if (!element) return;

    const pick: PendingPick = {
      element,
      ref: elementRef(element),
      index: this.session.count + 1,
    };
    if (this.options.captureScreenshots !== false) {
      pick.screenshotPNG = await screenshotPNG(element);
    }
    this.setMode({ kind: "commenting", pick });
  }

  /**
   * A dragged rectangle. The gesture people asked for, not a fallback: plenty of
   * real feedback is about something no element corresponds to.
   */
  pickRegion(rect: Rect): void {
    this.resolveDraftAndResumePicking();
    if (this.mode.kind !== "picking") return;
    this.tool = "box";
    const ref = regionRef(rect, {
      width: this.view.innerWidth,
      height: this.view.innerHeight,
    });
    if (!ref) return;
    this.setMode({
      kind: "commenting",
      pick: { ref, index: this.session.count + 1 },
    });
  }

  /**
   * A drawn shape.
   *
   * A stroke that encloses nothing is a pointer that slipped, or a swipe, and it
   * becomes the click it was always going to be. Refusing would lose the gesture
   * entirely and explain nothing.
   */
  pickPath(drawn: PathPoint[]): void {
    this.resolveDraftAndResumePicking();
    if (this.mode.kind !== "picking") return;

    const ref = pathRef(drawn, {
      width: this.view.innerWidth,
      height: this.view.innerHeight,
    });
    const first = drawn[0];
    if (!ref) {
      // Back to a click, and out of Draw - leaving it lit would put the next drag
      // straight back into a shape nobody asked for.
      this.tool = "point";
      if (first) void this.pickAt(first[0], first[1]);
      return;
    }
    this.setMode({
      kind: "commenting",
      pick: { ref, index: this.session.count + 1 },
    });
  }

  /**
   * Pointing somewhere else while a comment is open.
   *
   * An empty draft is thrown away, because nothing was said. A draft with words in
   * it becomes a note first: silently discarding what somebody typed is the one
   * unacceptable option, and the tray already has per-note delete.
   */
  resolveDraftAndResumePicking(): void {
    if (this.mode.kind !== "commenting") return;
    if (this.draft.comment.trim()) {
      this.saveComment();
      this.resumePicking();
    } else {
      this.cancelComment();
    }
  }

  /** Backing out of a comment returns you to picking, not out of annotate mode. */
  cancelComment(): void {
    if (this.mode.kind !== "commenting") return;
    this.draft = { comment: "", tag: undefined };
    this.setMode({ kind: "picking" });
  }

  saveComment(): Annotation | undefined {
    if (this.mode.kind !== "commenting") return undefined;
    const comment = this.draft.comment.trim();
    if (!comment) return undefined;

    const { pick } = this.mode;
    const annotation: Annotation = {
      id: uuid(),
      comment,
      element: pick.ref,
      capturedAt: new Date().toISOString(),
      viewport: this.viewport(),
      screen: this.options.screen?.() ?? this.view.location?.pathname,
    };
    // The endpoints behind the element are the reason this tool exists, so they are
    // read at save time rather than at pick time: the request the click itself
    // triggered has usually only just landed.
    const trace = this.options.network?.recent() ?? [];
    if (trace.length) annotation.trace = trace;
    const logs = this.options.logs?.recent() ?? [];
    if (logs.length) annotation.logs = logs;
    if (this.draft.tag) annotation.tag = this.draft.tag;
    if (pick.screenshotPNG) annotation.screenshotPNG = pick.screenshotPNG;

    this.session.add(annotation);
    this.draft = { comment: "", tag: undefined };
    this.setMode({ kind: "browsing" });
    return annotation;
  }

  resumePicking(): void {
    if (this.mode.kind !== "browsing") return;
    this.setMode({ kind: "picking" });
  }

  async send(): Promise<void> {
    if (this.session.isEmpty || this.sendState.kind === "sending") return;
    const count = this.session.count;
    this.sendState = { kind: "sending" };
    this.render();
    try {
      await this.session.send();
      this.sendState = { kind: "sent", count };
      // Send is the end of the job. An empty overlay left over someone's app is
      // clutter they now have to dismiss.
      this.setMode({ kind: "off" });
    } catch (error) {
      this.sendState = { kind: "failed", why: message(error) };
      // The tray is where the failure is readable and where Try again lives, so a
      // failed send always ends up there - wherever it was started from.
      this.setMode({ kind: "browsing" });
    }
  }

  destroy(): void {
    this.listeners.forEach((off) => off());
    this.listeners = [];
    this.host.remove();
  }

  // MARK: - Input

  private setMode(next: OverlayMode): void {
    if (next.kind === "commenting" && this.mode.kind !== "commenting") {
      this.popoverIsNew = true;
    }
    this.mode = next;
    this.updatePageListeners();
    this.render();
  }

  private installShortcuts(): void {
    const onKey = (event: KeyboardEvent) => {
      // ⌥⌘L on a Mac, Alt+Ctrl+L everywhere else.
      if (event.altKey && (event.metaKey || event.ctrlKey)
          && event.key.toLowerCase() === "l") {
        event.preventDefault();
        this.toggle();
        return;
      }
      if (event.key === "Escape" && this.mode.kind !== "off") {
        event.preventDefault();
        this.mode.kind === "commenting" ? this.cancelComment() : this.end();
      }
    };
    this.view.addEventListener("keydown", onKey, true);
    this.listeners.push(() => this.view.removeEventListener("keydown", onKey, true));
  }

  private pageListeners: Array<() => void> = [];

  /**
   * Clicks are taken from the page only while picking. While commenting, the
   * popover's own controls need them, and while browsing the whole point is that
   * the page behaves normally.
   */
  /** The rectangle being dragged out right now, in viewport coordinates. */
  private dragRect?: Rect;
  /** The shape being drawn right now, unthinned so the line sits under the pointer. */
  private dragPath?: PathPoint[];

  /**
   * Which gesture is meant.
   *
   * `point` and `box` are predictions: a click picks and a drag makes a rectangle
   * whichever is lit, and the control moves to match what you did. `draw` is the one
   * that decides, because a drawn shape and a dragged rectangle are the same gesture
   * and nothing in the pointer says which. That makes it the only tool somebody can
   * be stuck in, so a click always still picks and always leaves it.
   */
  private tool: PickTool = "point";

  private updatePageListeners(): void {
    this.pageListeners.forEach((off) => off());
    this.pageListeners = [];
    // Also while commenting: pointing somewhere else used to hit nothing, so the
    // only way to change your mind was to find Cancel first.
    if (this.mode.kind !== "picking" && this.mode.kind !== "commenting") return;

    const onMove = (event: MouseEvent) => {
      if (this.dragRect) return;
      const element = pickElement(event.clientX, event.clientY, this.doc,
                                  (hit) => this.isOurs(hit));
      if (!element) return;
      if (this.mode.kind === "picking" && this.mode.hover !== element) {
        this.mode = { kind: "picking", hover: element };
        this.render();
      }
    };
    // A drag draws a region, a click picks an element. Which one it was is not
    // known until the mouse comes back up, so the click handler has to be told.
    let origin: { x: number; y: number } | undefined;
    let dragged = false;

    const onDown = (event: MouseEvent) => {
      if (this.isOurs(event.target as Node)) return;
      origin = { x: event.clientX, y: event.clientY };
      dragged = false;
      // Draw records from the first pixel, or the top of every stroke is missing.
      // Box waits for a threshold, or a click that moves two pixels becomes a
      // rectangle nobody meant. Same event, two different questions.
      this.dragPath = this.tool === "draw" ? [[event.clientX, event.clientY]] : undefined;
    };

    const onDragMove = (event: MouseEvent) => {
      if (!origin) return;
      if (this.tool === "draw") {
        dragged = true;
        this.dragPath = [...(this.dragPath ?? []), [event.clientX, event.clientY]];
        this.render();
        return;
      }
      const rect = between(origin, { x: event.clientX, y: event.clientY });
      if (!dragged && rect.width < MINIMUM_REGION_SIZE && rect.height < MINIMUM_REGION_SIZE) {
        return;
      }
      dragged = true;
      this.dragRect = rect;
      this.render();
    };

    const onUp = (event: MouseEvent) => {
      const start = origin;
      origin = undefined;
      if (!start || !dragged) return;
      if (this.tool === "draw") {
        const drawn = [...(this.dragPath ?? []), [event.clientX, event.clientY]] as PathPoint[];
        this.dragPath = undefined;
        this.pickPath(drawn);
        return;
      }
      this.dragRect = undefined;
      this.pickRegion(between(start, { x: event.clientX, y: event.clientY }));
    };

    const onClick = (event: MouseEvent) => {
      if (this.isOurs(event.target as Node)) return;
      event.preventDefault();
      event.stopPropagation();
      // The click that ends a drag is not a click on anything.
      if (dragged) {
        dragged = false;
        return;
      }
      void this.pickAt(event.clientX, event.clientY);
    };

    this.doc.addEventListener("mousemove", onMove, true);
    this.doc.addEventListener("mousedown", onDown, true);
    this.doc.addEventListener("mousemove", onDragMove, true);
    this.doc.addEventListener("mouseup", onUp, true);
    this.doc.addEventListener("click", onClick, true);
    this.pageListeners.push(
      () => this.doc.removeEventListener("mousemove", onMove, true),
      () => this.doc.removeEventListener("mousedown", onDown, true),
      () => this.doc.removeEventListener("mousemove", onDragMove, true),
      () => this.doc.removeEventListener("mouseup", onUp, true),
      () => this.doc.removeEventListener("click", onClick, true),
    );
  }

  /**
   * The overlay must never annotate itself.
   *
   * No `instanceof Element` here: an element from an iframe belongs to another
   * realm, where that check is false against this window's constructor. Duck-typing
   * on `getRootNode` is both realm-safe and shorter.
   */
  private isOurs(node: Node | null): boolean {
    if (!node) return false;
    if (node === this.host || this.host.contains(node)) return true;
    return typeof node.getRootNode === "function" && node.getRootNode() === this.root;
  }

  private viewport(): Rect {
    return { x: 0, y: 0, width: this.view.innerWidth, height: this.view.innerHeight };
  }

  /**
   * A closed shape, as an SVG overlay sized to the viewport.
   *
   * SVG rather than a canvas: it scales, it needs no redraw on resize, and the
   * even-odd fill rule the format documents is one attribute. A hand-drawn shape
   * crosses itself constantly, and winding would fill the crossings solid.
   */
  private pathShape(points: PathPoint[], className: string): Element {
    const svg = this.doc.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("class", className);
    svg.setAttribute("aria-hidden", "true");
    const polygon = this.doc.createElementNS("http://www.w3.org/2000/svg", "polygon");
    polygon.setAttribute("points", points.map(([x, y]) => `${x},${y}`).join(" "));
    polygon.setAttribute("fill-rule", "evenodd");
    svg.append(polygon);
    return svg;
  }

  // MARK: - Drawing

  private render(): void {
    for (const node of [...this.root.children]) {
      if (node.tagName !== "STYLE") node.remove();
    }
    if (this.mode.kind === "off") return;

    if (swallowsInput(this.mode)) {
      this.root.append(this.element("div", { class: "scrim" }));
    }

    // The dragged rectangle wins while it is being drawn. Showing the hover
    // highlight underneath it as well says two different things about what is
    // about to be captured.
    if (this.dragRect) {
      const r = this.dragRect;
      this.root.append(this.element("div", {
        class: "drag-region",
        style: `left:${r.x}px;top:${r.y}px;width:${r.width}px;height:${r.height}px`,
        "aria-hidden": "true",
      }));
    }

    // Dashed, exactly like the rectangle: a solid outline is what a committed pick
    // looks like, and the two must never be confused.
    if (this.dragPath && this.dragPath.length >= 2) {
      this.root.append(this.pathShape(this.dragPath, "drag-path"));
    }

    const highlighted = this.dragRect || this.dragPath ? undefined
      : this.mode.kind === "picking" ? this.mode.hover
      : this.mode.kind === "commenting" ? this.mode.pick.element
      : undefined;
    if (highlighted) {
      const index = this.mode.kind === "commenting"
        ? this.mode.pick.index : this.session.count + 1;
      this.root.append(...this.highlight(highlighted, index));
    }

    // A committed shape draws itself, not a rectangle around itself. Pinning a lasso
    // inside a box would be the overlay showing back the one thing the gesture
    // refused to say.
    if (this.mode.kind === "commenting" && this.mode.pick.ref.path) {
      this.root.append(this.pathShape(this.mode.pick.ref.path, "path-shape"));
    } else if (this.mode.kind === "commenting" && !this.mode.pick.element) {
      // A committed region has no element to outline, so it draws its own.
      const r = this.mode.pick.ref.bounds;
      this.root.append(
        this.element("div", {
          class: "highlight",
          style: `left:${r.x}px;top:${r.y}px;width:${r.width}px;height:${r.height}px`,
          "aria-hidden": "true",
        }),
        this.element("div", {
          class: "badge",
          style: `left:${r.x}px;top:${r.y}px`,
        }, String(this.mode.pick.index)),
      );
    }

    if (this.mode.kind === "commenting") this.root.append(this.popover(this.mode.pick));

    // The full tray belongs to browsing. While you are picking, it would cover part
    // of the page - and anything under it cannot be pointed at, which is the one
    // thing the tool must never take away.
    const reviewing = this.mode.kind === "browsing" && !this.session.isEmpty;
    this.root.append(reviewing ? this.tray() : this.hint());
  }

  private highlight(element: Element, index: number): Element[] {
    const box = element.getBoundingClientRect();

    const outline = this.element("div", {
      class: "highlight",
      style: `left:${box.left}px;top:${box.top}px;width:${box.width}px;height:${box.height}px`,
      "aria-hidden": "true",
    });
    const badge = this.element("div", {
      class: "badge",
      style: `left:${box.left}px;top:${box.top}px`,
    }, String(index));
    return [outline, badge];
  }

  private popover(pick: PendingPick): Element {
    const box = boxOf(pick);
    const width = 320;
    const height = 260;
    const gap = 12;

    // Below when there is room, above when there is not. It flips side rather than
    // covering the element, which is the one thing it must never do.
    const below = box.bottom + gap;
    const above = box.top - gap - height;
    const top = below + height <= this.view.innerHeight ? below
      : above >= 0 ? above
      : Math.max(0, Math.min(below, this.view.innerHeight - height));
    const left = Math.max(0,
      Math.min(box.left + box.width / 2 - width / 2, this.view.innerWidth - width));

    const panel = this.element("div", {
      class: "panel popover",
      style: `left:${left}px;top:${top}px`,
      role: "dialog",
      "aria-label": `Comment on ${pick.ref.label ?? pick.ref.className ?? "element"}`,
    });

    const head = this.element("div", { class: "head" });
    head.append(this.element("div", { class: "badge" }, String(pick.index)));
    const names = this.element("div");
    // A region is not an element and must not be labelled as one: calling a
    // rectangle somebody drew "Element" is the panel disagreeing with what they
    // just did.
    const isRegion = pick.ref.kind === "region";
    names.append(this.element("div", { class: "name" },
      isRegion ? "Region" : pick.ref.label ?? pick.ref.accessibilityID ?? "Element"));
    const detail = isRegion
      ? `${Math.round(pick.ref.bounds.width)}\u00d7${Math.round(pick.ref.bounds.height)}`
      : pick.ref.accessibilityID ?? pick.ref.selector;
    if (detail) names.append(this.element("div", { class: "detail" }, detail));
    head.append(names);

    const field = this.element("textarea", {
      placeholder: "What is wrong with this?",
      "aria-label": "Comment",
    }) as HTMLTextAreaElement;
    field.value = this.draft.comment;

    const chips = this.element("div", { class: "chips" });
    const save = this.element("button", { class: "primary" }, "Save") as HTMLButtonElement;
    save.disabled = !this.draft.comment.trim();

    for (const tag of ["bug", "idea", "polish", "question"] as AnnotationTag[]) {
      const chip = this.element("button", {
        class: "chip",
        style: `--chip-colour:${tagColour[tag]}`,
        "aria-pressed": String(this.draft.tag === tag),
        "aria-label": `Tag as ${tag}`,
      }, tag) as HTMLButtonElement;
      chip.addEventListener("click", () => {
        // Tapping the chosen tag clears it: a tag is a hint, and you have to be able
        // to say you do not know which of these it is.
        this.draft.tag = this.draft.tag === tag ? undefined : tag;
        this.render();
      });
      chips.append(chip);
    }

    field.addEventListener("input", () => {
      this.draft.comment = field.value;
      save.disabled = !field.value.trim();
    });

    const row = this.element("div", { class: "row" });
    const cancel = this.element("button", { class: "quiet" }, "Cancel");
    cancel.addEventListener("click", () => this.cancelComment());
    save.addEventListener("click", () => this.saveComment());
    row.append(cancel, this.element("div", { class: "spacer" }), save);

    panel.append(head, field, chips, row);
    if (this.popoverIsNew) {
      // Focused on open: the overlay must never make someone wait to leave a note.
      this.popoverIsNew = false;
      this.view.setTimeout(() => field.focus(), 0);
    }
    return panel;
  }

  /** What each tool is called and what it means, in the fewest true words. */
  private static readonly TOOLS: ReadonlyArray<{
    tool: PickTool; glyph: string; label: string;
  }> = [
    { tool: "point", glyph: "\u25CE", label: "Point: click an element" },
    { tool: "box", glyph: "\u2B1A", label: "Box: drag a rectangle" },
    { tool: "draw", glyph: "\u2941", label: "Draw: trace a shape around several things" },
  ];

  /** The gesture you can make, on screen. Nothing said so, and lasso does not exist
   * until something does: an undiscoverable mode is the same as a missing one. */
  private tools(): Element {
    const group = this.element("div", { class: "tools", role: "group",
                                        "aria-label": "Selection tool" });
    for (const { tool, glyph, label } of Overlay.TOOLS) {
      const button = this.element("button", {
        class: this.tool === tool ? "tool on" : "tool",
        "aria-label": label,
        "aria-pressed": String(this.tool === tool),
      }, glyph);
      button.addEventListener("click", () => {
        this.tool = tool;
        this.render();
      });
      group.append(button);
    }
    return group;
  }

  private hint(): Element {
    const panel = this.element("div", { class: "panel hint" });
    const count = this.session.count;
    if (this.mode.kind === "picking") panel.append(this.tools());
    panel.append(this.doc.createTextNode(
      count === 0 ? "Point at something that looks wrong."
        : count === 1 ? "1 note · point at another"
        : `${count} notes · point at another`));

    if (count > 0 && this.mode.kind !== "commenting") {
      const review = this.element("button", { class: "quiet" }, "Review");
      review.addEventListener("click", () => this.setMode({ kind: "browsing" }));
      panel.append(review);
    }
    const close = this.element("button", { class: "quiet", "aria-label": "Leave annotate mode" }, "✕");
    close.addEventListener("click", () => this.end());
    panel.append(close);
    return panel;
  }

  private tray(): Element {
    const panel = this.element("div", { class: "panel tray", role: "region",
                                        "aria-label": "Annotations" });

    const header = this.element("header");
    header.append(this.element("div", { class: "title" },
      this.session.count === 1 ? "1 note" : `${this.session.count} notes`));
    header.append(this.element("div", { class: "spacer" }));

    const another = this.element("button", { class: "quiet" }, "Pick another") as HTMLButtonElement;
    another.disabled = this.mode.kind !== "browsing";
    another.addEventListener("click", () => this.resumePicking());

    const close = this.element("button", { class: "quiet", "aria-label": "Leave annotate mode" }, "✕");
    close.addEventListener("click", () => this.end());
    header.append(another, close);

    const list = this.element("div", { class: "list" });
    this.session.annotations.forEach((annotation, index) => {
      list.append(this.item(annotation, index + 1));
    });

    const footer = this.element("footer");
    if (this.pendingCount > 0) {
      const retry = this.element("button", { class: "quiet" },
        this.pendingCount === 1 ? "1 bundle waiting to send"
          : `${this.pendingCount} bundles waiting to send`);
      retry.addEventListener("click", () => void this.options.queue?.drainWithRetry());
      footer.append(retry);
    }
    const send = this.element("button", { class: "primary" },
      this.sendTitle()) as HTMLButtonElement;
    send.disabled = this.session.isEmpty || this.sendState.kind === "sending";
    send.addEventListener("click", () => void this.send());
    footer.append(send);

    panel.append(header, list);
    if (this.sendState.kind === "failed") {
      // The reader is a developer looking at their own staging build. The real
      // reason is more use to them than a reassuring sentence.
      panel.append(this.element("div", { class: "failed" }, this.sendState.why));
    }
    panel.append(footer);
    return panel;
  }

  private item(annotation: Annotation, index: number): Element {
    const row = this.element("div", { class: "item" });
    row.append(this.element("div", { class: "badge" }, String(index)));

    const body = this.element("div", { class: "body" });
    if (annotation.screenshotPNG) {
      const image = this.element("img", {
        src: `data:image/png;base64,${annotation.screenshotPNG}`,
        alt: "",
      });
      body.append(image);
    }
    body.append(this.element("div", { class: "comment" }, annotation.comment));

    const detail = annotation.element.accessibilityID ?? annotation.element.selector;
    if (detail) body.append(this.element("div", { class: "meta" }, detail));

    for (const line of endpoints(annotation)) {
      body.append(this.element("div", { class: "meta" }, line));
    }
    const errors = (annotation.logs ?? []).filter((l) => l.level === "error");
    if (errors[0]) {
      body.append(this.element("div", { class: "meta errors" },
        errors.length === 1 ? errors[0].message
          : `${errors[0].message} (+${errors.length - 1} more)`));
    }
    if (annotation.tag) {
      body.append(this.element("div", {
        class: "tag", style: `color:${tagColour[annotation.tag]}`,
      }, annotation.tag));
    }

    const remove = this.element("button", {
      class: "quiet", "aria-label": `Remove annotation ${index}`,
    }, "🗑");
    remove.addEventListener("click", () => this.session.remove(annotation.id));

    row.append(body, remove);
    return row;
  }

  private sendTitle(): string {
    switch (this.sendState.kind) {
      case "sending": return "Sending…";
      case "failed": return "Try again";
      case "sent": return `Sent ${this.sendState.count}`;
      case "idle":
        return this.session.count === 1 ? "Send 1 note" : `Send ${this.session.count} notes`;
    }
  }

  private element(tag: string, attributes: Record<string, string> = {},
                  text?: string): HTMLElement {
    const node = this.doc.createElement(tag);
    for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
    if (text !== undefined) node.textContent = text;
    return node;
  }
}

/** At most three, newest first. A wall of polling requests helps nobody. */
function endpoints(annotation: Annotation): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const event of [...(annotation.trace ?? [])].reverse()) {
    let path = event.url;
    try { path = new URL(event.url, "http://x").pathname; } catch { /* keep the raw url */ }
    const line = `${event.method} ${path}${event.statusCode ? ` ${event.statusCode}` : ""}`;
    if (!seen.has(line)) { seen.add(line); result.push(line); }
    if (result.length === 3) break;
  }
  return result;
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
