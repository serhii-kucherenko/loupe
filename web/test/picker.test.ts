import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

import {
  isMeaningful, meaningfulAncestor, namedBy, elementRef, cssSelector, labelOf,
} from "../src/picker.js";

/**
 * jsdom does no layout, so `getBoundingClientRect` returns zeros. Tests that care
 * about geometry state it on the element and read it back, which keeps the numbers
 * visible in the test rather than hidden in a helper.
 */
function dom(html: string): { document: Document; window: Window } {
  const jsdom = new JSDOM(`<!doctype html><body>${html}</body>`);
  const { document, Element } = jsdom.window;

  Element.prototype.getBoundingClientRect = function (this: Element) {
    const raw = this.getAttribute("data-rect");
    const [x, y, width, height] = raw ? raw.split(",").map(Number) : [0, 0, 0, 0];
    return {
      x, y, width, height,
      left: x, top: y, right: x! + width!, bottom: y! + height!,
      toJSON: () => ({}),
    } as DOMRect;
  };
  return { document, window: jsdom.window as unknown as Window };
}

const q = (document: Document, selector: string): Element => {
  const found = document.querySelector(selector);
  assert.ok(found, `no ${selector}`);
  return found;
};

test("it climbs past an inner span to the named card", () => {
  const { document } = dom(`
    <div data-testid="product.card" data-rect="0,0,300,120">
      <span id="title" data-rect="10,10,200,20">Wool overshirt</span>
    </div>`);

  const picked = meaningfulAncestor(q(document, "span"), 1000 * 800);
  assert.equal(namedBy(picked), "title",
    "an element with an id is named, so the climb stops there");

  const unnamed = dom(`
    <div data-testid="product.card" data-rect="0,0,300,120">
      <span data-rect="10,10,200,20">Wool overshirt</span>
    </div>`);
  const climbed = meaningfulAncestor(q(unnamed.document, "span"), 1000 * 800);
  assert.equal(namedBy(climbed), "product.card");
});

test("it stops at an interactive element even when nothing named it", () => {
  const { document } = dom(`<button><span>Buy</span></button>`);
  const picked = meaningfulAncestor(q(document, "span"), 1000 * 800);
  assert.equal(picked.tagName, "BUTTON");
});

test("a role makes an element interactive, an aria-label alone does not", () => {
  const { document } = dom(`
    <div role="button" data-rect="0,0,100,40"><i aria-label="cart"></i></div>`);

  // The icon carries a screen-reader label and nothing else. Stopping there would be
  // the web version of treating a static label as a control.
  assert.equal(isMeaningful(q(document, "i")), false);
  assert.equal(meaningfulAncestor(q(document, "i"), 1000 * 800).getAttribute("role"), "button");
});

test("a negative tabindex is script focus, not a person's affordance", () => {
  const { document } = dom(`<div tabindex="-1"><em>x</em></div>`);
  assert.equal(isMeaningful(q(document, "div")), false);

  const positive = dom(`<div tabindex="0"><em>x</em></div>`);
  assert.equal(isMeaningful(q(positive.document, "div")), true);
});

test("the climb never swallows the viewport", () => {
  const { document } = dom(`
    <main id="app" data-rect="0,0,1000,800">
      <div data-rect="10,10,50,50"><em data-rect="12,12,20,20">x</em></div>
    </main>`);

  const picked = meaningfulAncestor(q(document, "em"), 1000 * 800);
  assert.notEqual(picked.id, "app", "a viewport-sized container is never what you meant");
});

test("the selector stops as soon as it is unique", () => {
  const { document } = dom(`
    <div class="list"><a href="#">one</a><a href="#">two</a></div>`);

  const second = document.querySelectorAll("a")[1]!;
  const selector = cssSelector(second, document);

  assert.equal(document.querySelectorAll(selector).length, 1, selector);
  assert.ok(selector.includes("nth-of-type(2)"), selector);
  assert.ok(selector.split(">").length <= 3, `too long to act on: ${selector}`);
});

test("a test id beats a positional selector", () => {
  const { document } = dom(`
    <div><span data-testid="price">£96.00</span><span>other</span></div>`);
  assert.equal(cssSelector(q(document, "[data-testid]"), document),
    'span[data-testid="price"]');
});

test("a framework-generated id is not written as a bare #id", () => {
  const { document } = dom(`<div id=":r3:" data-rect="0,0,10,10">x</div>`);
  const selector = cssSelector(q(document, "div"), document);
  assert.ok(!selector.startsWith("#"), `#:r3: is not a valid selector: ${selector}`);
  assert.equal(document.querySelectorAll(selector).length, 1);
});

test("the label is the accessible name, then the text, and never a paragraph", () => {
  const { document } = dom(`
    <p id="long">${"word ".repeat(60)}</p>
    <button aria-label="Add to basket"><span>+</span></button>
    <img id="pic" alt="Blue jacket">`);

  assert.equal(labelOf(q(document, "button")), "Add to basket");
  assert.equal(labelOf(q(document, "#pic")), "Blue jacket");

  const long = labelOf(q(document, "#long"))!;
  assert.ok(long.length <= 80, `label was ${long.length} characters`);
  assert.ok(long.endsWith("…"));
});

test("an element reference carries what an agent can act on", () => {
  const { document } = dom(`
    <div data-testid="cart.empty" data-rect="300,260,300,120">Your basket is empty</div>`);

  const ref = elementRef(q(document, "div"));
  assert.equal(ref.accessibilityID, "cart.empty");
  assert.equal(ref.label, "Your basket is empty");
  assert.equal(ref.className, "div");
  assert.equal(ref.selector, 'div[data-testid="cart.empty"]');
  assert.deepEqual(ref.bounds, { x: 300, y: 260, width: 300, height: 120 });
});
