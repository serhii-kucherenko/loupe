import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

import { Overlay, swallowsInput } from "../src/overlay.js";
import { AnnotationSession } from "../src/session.js";
import type { AnnotationBundle } from "../src/types.js";
import type { Transport } from "../src/transport.js";
import { NetworkRecorder } from "../src/recorder.js";

class Spy implements Transport {
  shouldFail = false;
  sent: AnnotationBundle[] = [];
  async send(bundle: AnnotationBundle) {
    if (this.shouldFail) throw new Error("triage returned 503");
    this.sent.push(bundle);
  }
}

/**
 * jsdom has no layout and no `elementFromPoint`, so both are supplied here. The
 * rectangles are declared on the elements themselves, which keeps the geometry a
 * test depends on visible in the test.
 */
function page(html: string) {
  const jsdom = new JSDOM(`<!doctype html><body>${html}</body>`, { pretendToBeVisual: true });
  const { window } = jsdom;
  const document = window.document;

  window.Element.prototype.getBoundingClientRect = function (this: Element) {
    const raw = this.getAttribute("data-rect");
    const [x, y, width, height] = raw ? raw.split(",").map(Number) : [0, 0, 0, 0];
    return { x, y, width, height, left: x, top: y,
             right: x! + width!, bottom: y! + height!, toJSON: () => ({}) } as DOMRect;
  };

  // Deepest declared rectangle containing the point, which is what a browser's
  // hit-testing arrives at.
  document.elementFromPoint = (x: number, y: number) => {
    const hits = [...document.querySelectorAll("[data-rect]")].filter((element) => {
      const box = element.getBoundingClientRect();
      return x >= box.left && x <= box.right && y >= box.top && y <= box.bottom;
    });
    return hits[hits.length - 1] ?? null;
  };

  Object.defineProperty(window, "innerWidth", { value: 1000, configurable: true });
  Object.defineProperty(window, "innerHeight", { value: 800, configurable: true });

  const transport = new Spy();
  const network = new NetworkRecorder();
  const session = new AnnotationSession({ name: "Demo", platform: "web" }, transport);
  const overlay = new Overlay(session, window as unknown as Window & typeof globalThis,
                              { captureScreenshots: false, network });
  return { window, document, session, overlay, transport, network };
}

// Read through a widening helper: node:assert narrows the union on the first
// comparison, so a second `assert.equal` on the same getter would be checking
// against `never` rather than against the mode.
const modeOf = (overlay: Overlay): string => overlay.currentMode.kind;

const shadow = (document: Document): ShadowRoot => {
  const host = document.querySelector("loupe-overlay");
  assert.ok(host?.shadowRoot, "no overlay");
  return host.shadowRoot;
};

test("the overlay draws nothing until it is asked to", () => {
  const { document, overlay } = page(`<div data-rect="0,0,100,40">x</div>`);
  assert.equal(modeOf(overlay), "off");
  assert.equal(shadow(document).querySelector(".panel"), null);
});

test("the whole pick, comment, save walk", async () => {
  const { document, overlay, session } = page(`
    <div data-testid="search.results" data-rect="40,150,420,36">
      <span data-rect="50,158,200,20">Wool overshirt</span>
    </div>`);

  overlay.begin();
  assert.equal(modeOf(overlay), "picking");
  assert.ok(shadow(document).querySelector(".hint"), "one line, not a full tray");

  await overlay.pickAt(100, 165);
  assert.equal(modeOf(overlay), "commenting");

  const field = shadow(document).querySelector("textarea") as HTMLTextAreaElement;
  assert.ok(field, "no comment field");
  field.value = "clearing the search leaves the old results";
  field.dispatchEvent(new document.defaultView!.Event("input"));

  (shadow(document).querySelector("button.primary") as HTMLButtonElement).click();

  assert.equal(modeOf(overlay), "browsing");
  assert.equal(session.count, 1);
  assert.equal(session.annotations[0]!.element.accessibilityID, "search.results",
    "the span inside is not what a person means by 'this row'");
});

test("only picking and commenting take the page's clicks", () => {
  assert.equal(swallowsInput({ kind: "off" }), false);
  assert.equal(swallowsInput({ kind: "picking" }), true);
  assert.equal(swallowsInput({ kind: "browsing" }), false,
    "you have to be able to navigate to a second screen");
});

test("an empty comment is not an annotation", async () => {
  const { document, overlay, session } = page(`<div data-rect="0,0,100,40">x</div>`);
  overlay.begin();
  await overlay.pickAt(50, 20);

  const save = shadow(document).querySelector("button.primary") as HTMLButtonElement;
  assert.equal(save.disabled, true);
  save.click();
  assert.equal(session.count, 0);
  assert.equal(modeOf(overlay), "commenting");
});

test("cancelling one pick does not leave annotate mode", async () => {
  const { document, overlay } = page(`<div data-rect="0,0,100,40">x</div>`);
  overlay.begin();
  await overlay.pickAt(50, 20);
  (shadow(document).querySelector("button.quiet") as HTMLButtonElement).click();
  assert.equal(modeOf(overlay), "picking");
});

test("the popover flips above rather than covering the element", async () => {
  const { document, overlay } = page(`<div data-rect="100,700,200,40">near the bottom</div>`);
  overlay.begin();
  await overlay.pickAt(150, 720);

  const popover = shadow(document).querySelector(".popover") as HTMLElement;
  const top = Number(popover.style.top.replace("px", ""));
  assert.ok(top + 260 <= 700, `popover at ${top} covers an element starting at 700`);
});

test("the tray shows the endpoint behind the element, which is the point", async () => {
  const { document, overlay, session, network } = page(`<div data-rect="0,0,100,40">x</div>`);
  network.record({
    method: "GET", url: "https://api.test/v2/search?q=",
    statusCode: 500, durationMs: 60, at: new Date().toISOString(),
  });
  overlay.begin();
  await overlay.pickAt(50, 20);
  const field = shadow(document).querySelector("textarea") as HTMLTextAreaElement;
  field.value = "stale";
  field.dispatchEvent(new document.defaultView!.Event("input"));
  (shadow(document).querySelector("button.primary") as HTMLButtonElement).click();

  const meta = [...shadow(document).querySelectorAll(".meta")].map((n) => n.textContent);
  assert.ok(meta.some((line) => line?.includes("GET /v2/search 500")), meta.join(" | "));
});

test("a successful send ships the tray and closes the overlay", async () => {
  const { overlay, session, transport } = page(`<div data-rect="0,0,100,40">x</div>`);
  session.add({
    id: crypto.randomUUID(), comment: "one",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  });
  overlay.begin();

  await overlay.send();
  assert.equal(transport.sent.length, 1);
  assert.equal(modeOf(overlay), "off", "Send is the end of the job");
  assert.equal(session.count, 0);
});

test("a failed send keeps the tray and says why", async () => {
  const { document, overlay, session, transport } = page(`<div data-rect="0,0,100,40">x</div>`);
  transport.shouldFail = true;
  session.add({
    id: crypto.randomUUID(), comment: "one",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  });
  overlay.begin();

  await overlay.send();
  assert.equal(session.count, 1, "nothing is lost on a failure");
  assert.equal(shadow(document).querySelector(".failed")?.textContent, "triage returned 503");
});

test("the overlay never annotates itself", async () => {
  const { document, overlay } = page(`<div data-rect="0,0,1000,800">page</div>`);
  overlay.begin();
  // The tray sits at the top right; a pick there must not resolve to the overlay.
  await overlay.pickAt(900, 30);
  if (overlay.currentMode.kind === "commenting") {
    const host = document.querySelector("loupe-overlay")!;
    assert.ok(!host.contains(overlay.currentMode.pick.element),
      "the overlay picked one of its own elements");
  }
});

test("the shortcut toggles, and Escape backs out one step at a time", async () => {
  const { document, overlay } = page(`<div data-rect="0,0,100,40">x</div>`);
  const press = (key: string, modifiers: Partial<KeyboardEventInit> = {}) =>
    document.defaultView!.dispatchEvent(
      new document.defaultView!.KeyboardEvent("keydown", { key, ...modifiers }));

  press("l", { altKey: true, metaKey: true });
  assert.equal(modeOf(overlay), "picking");

  await overlay.pickAt(50, 20);
  press("Escape");
  assert.equal(modeOf(overlay), "picking", "Escape cancels the comment first");

  press("Escape");
  assert.equal(modeOf(overlay), "off");
});

test("the stylesheet holds no literal colour", () => {
  const { document } = page("");
  const css = shadow(document).querySelector("style")!.textContent!;
  const rules = css.split(":host")[2] ?? css;   // past the token blocks
  assert.equal(/#[0-9a-fA-F]{6}\b/.test(rules), false, "a raw hex escaped into the rules");
});

test("a point over the tray picks nothing, rather than picking the whole page", async () => {
  const { document, overlay, session } = page(`
    <div data-rect="0,0,1000,800">the page</div>`);
  session.add({
    id: crypto.randomUUID(), comment: "already here",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  });
  overlay.begin();

  // elementFromPoint retargets shadow content to the host, so this is what a click
  // on the tray actually looks like to the picker.
  const host = document.querySelector("loupe-overlay")!;
  host.setAttribute("data-rect", "660,16,340,700");

  await overlay.pickAt(800, 100);
  assert.equal(overlay.currentMode.kind, "picking",
    "clicking the tray must not pin an element");
  assert.equal(session.count, 1, "and must not add an annotation");
});

test("the full tray belongs to browsing, so picking can reach the whole page", async () => {
  const { document, overlay, session } = page(`<div data-rect="0,0,200,40">x</div>`);
  overlay.begin();
  await overlay.pickAt(50, 20);

  const field = shadow(document).querySelector("textarea") as HTMLTextAreaElement;
  field.value = "one";
  field.dispatchEvent(new document.defaultView!.Event("input"));
  (shadow(document).querySelector("button.primary") as HTMLButtonElement).click();

  assert.ok(shadow(document).querySelector(".tray"), "after a save you are reviewing");

  overlay.resumePicking();
  assert.equal(shadow(document).querySelector(".tray"), null,
    "while picking the tray must not sit over the page");
  const bar = shadow(document).querySelector(".hint")!;
  assert.match(bar.textContent!, /1 note/, "the count still has to be visible");
  assert.equal(session.count, 1);
});
