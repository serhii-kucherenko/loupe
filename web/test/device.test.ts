import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

import { start } from "../src/index.js";
import type { AnnotationBundle, Annotation } from "../src/types.js";
import type { Transport } from "../src/transport.js";

/**
 * A bundle gets pasted into tickets and public repositories. What the web SDK says
 * about the machine is therefore a promise as much as a feature: the screen, so a
 * layout bug is reproducible, and nothing a fingerprinter would want.
 */

/**
 * A real jsdom window, with the screen dictated by the test. jsdom reports a screen
 * of its own, so it is overwritten rather than trusted - the number in the assertion
 * should be the number in the test.
 */
function fakeWindow(screen?: { width: number; height: number }, dpr = 2) {
  const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true });
  Object.defineProperty(window, "screen", { value: screen, configurable: true });
  Object.defineProperty(window, "devicePixelRatio", { value: dpr, configurable: true });
  return window as unknown as Window & typeof globalThis;
}

class Collect implements Transport {
  sent: AnnotationBundle[] = [];
  async send(bundle: AnnotationBundle) { this.sent.push(bundle); }
}

function note(): Annotation {
  return {
    id: "1D2C3B4A-0000-4000-8000-000000000001",
    comment: "the row is cut off",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 8, height: 8 } },
  } as Annotation;
}

/** What actually travels, which is the only thing worth asserting on. */
async function bundle(options: { device?: unknown; screen?: { width: number; height: number } }) {
  const transport = new Collect();
  const app: Record<string, unknown> = { name: "Acme", platform: "web" };
  if (options.device) app.device = options.device;
  const loupe = start({
    app: app as never,
    transport,
    window: fakeWindow(options.screen),
  });
  loupe.session.add(note());
  await loupe.session.send();
  loupe.stop();
  const sent = transport.sent[0];
  assert.ok(sent, "the send has to have reached the transport at all");
  return sent;
}

test("the screen is filled in without the host being asked", async () => {
  const sent = await bundle({ screen: { width: 1512, height: 982 } });

  assert.deepEqual(sent.app.device?.screen, { width: 1512, height: 982, scale: 2 });
});

test("a host that supplied its own device is left alone", async () => {
  const mine = { screen: { width: 1, height: 2, scale: 3 } };
  const sent = await bundle({ device: mine, screen: { width: 1512, height: 982 } });

  assert.deepEqual(sent.app.device, mine);
});

test("a window with no screen leaves the field absent rather than wrong", async () => {
  const sent = await bundle({});

  assert.equal(sent.app.device, undefined);
});

/**
 * The rule, asserted on the JSON rather than on the type, because the JSON is what
 * travels into somebody's ticket.
 */
test("nothing a fingerprinter would want reaches the bundle", async () => {
  const sent = await bundle({ screen: { width: 1512, height: 982 } });

  const json = JSON.stringify(sent.app).toLowerCase();
  for (const forbidden of ["useragent", "locale", "timezone", "language", "platformversion"]) {
    assert.ok(!json.includes(forbidden), `${forbidden} in ${json}`);
  }
});
