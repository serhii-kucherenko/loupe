import { test } from "node:test";
import assert from "node:assert/strict";

import { cssVariables } from "../src/tokens.js";

/**
 * The overlay lives in a shadow root, so a host page's stylesheet cannot reach in.
 * That is deliberate - a staging app with a global `* { box-sizing }` reset would
 * otherwise reshape the tool sitting on top of it - and it also means these
 * variables are the *only* way a host can say "use my colours".
 *
 * The Swift SDK has the same hook, and `LoupeThemeTests` / `HostThemeTests` hold it
 * to the same rules: name only what you have an opinion about, and the wash follows
 * the accent without being asked.
 */

/** The declarations inside `:host { ... }`, before the dark-scheme block. */
function light(css: string): string {
  return css.slice(0, css.indexOf("@media"));
}

function dark(css: string): string {
  return css.slice(css.indexOf("@media"));
}

test("with no theme, the variables are Loupe's own", () => {
  const css = cssVariables();
  assert.match(light(css), /--loupe-highlight: rgb\(181 85 29\)/);
  assert.match(dark(css), /--loupe-highlight: rgb\(226 154 90\)/);
});

test("a host's accent wins, and it wins last so nothing has to know about it", () => {
  const css = light(cssVariables({ accent: "#4338CA" }));
  const stock = css.indexOf("--loupe-highlight: rgb(181 85 29)");
  const host = css.indexOf("--loupe-highlight: #4338CA");

  assert.ok(host > stock, "the host's value has to come after Loupe's to win");
});

test("a host can point straight at its own CSS variable", () => {
  // The reason colours are CSS strings rather than parsed hex: a host page that
  // already has `--brand` should not have to restate its value here, where it would
  // then be two values that can disagree.
  const css = cssVariables({ accent: "var(--brand)" });
  assert.match(light(css), /--loupe-highlight: var\(--brand\)/);
});

test("the wash follows the accent without being asked, in both schemes", () => {
  const css = cssVariables({ accent: "#4338CA" });
  assert.match(light(css),
    /--loupe-highlight-fill: color-mix\(in srgb, #4338CA 10%, transparent\)/);
  assert.match(dark(css),
    /--loupe-highlight-fill: color-mix\(in srgb, #4338CA 14%, transparent\)/);
});

test("a host with its own wash keeps it", () => {
  const css = light(cssVariables({ accent: "#4338CA", accentFill: "#00FF0033" }));
  assert.match(css, /--loupe-highlight-fill: #00FF0033/);
  assert.doesNotMatch(css, /color-mix/);
});

test("a colour with two schemes lands in the matching block", () => {
  const css = cssVariables({ ink: { light: "#111111", dark: "#EEEEEE" } });
  assert.match(light(css), /--loupe-ink: #111111/);
  assert.match(dark(css), /--loupe-ink: #EEEEEE/);
});

test("radii and the font stack come through", () => {
  const css = light(cssVariables({
    panelRadius: 28, controlRadius: 20, fontFamily: "Inter, sans-serif",
  }));
  assert.match(css, /--loupe-radius-panel: 28px/);
  assert.match(css, /--loupe-radius-control: 20px/);
  assert.match(css, /font-family: Inter, sans-serif/);
});

test("omitting a field keeps Loupe's own value", () => {
  const css = light(cssVariables({ accent: "#4338CA" }));
  // Named once, by Loupe, and never overridden.
  assert.equal(css.match(/--loupe-ink:/g)?.length, 1);
  assert.match(css, /--loupe-radius-panel: 16px/);
});
