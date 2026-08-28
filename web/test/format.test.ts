import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
// The schema declares draft 2020-12, so it needs ajv's 2020 entry point.
import Ajv from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

import { AnnotationSession } from "../src/session.js";
import { CURRENT_FORMAT_VERSION, uuid, type AnnotationBundle } from "../src/types.js";

/**
 * The bundle format is the contract between this SDK, the Swift one, and anything
 * that consumes bundles. Both SDKs are held to the same schema file, which is the
 * only thing that stops "the same format" from quietly becoming two formats.
 */

const here = dirname(fileURLToPath(import.meta.url));
const docs = join(here, "..", "..", "..", "docs");

const ajv = new Ajv({ strict: false });
addFormats(ajv);
const validate = ajv.compile(JSON.parse(readFileSync(join(docs, "bundle-format.schema.json"), "utf8")));

function check(bundle: unknown): void {
  if (!validate(bundle)) {
    assert.fail(ajv.errorsText(validate.errors, { separator: "\n" }));
  }
}

test("the documented example validates", () => {
  check(JSON.parse(readFileSync(join(docs, "bundle-format.example.json"), "utf8")));
});

test("a bundle this SDK produces validates against the shared schema", async () => {
  let shipped: AnnotationBundle | undefined;
  const session = new AnnotationSession(
    { name: "Acme", version: "1.4.0", commitSHA: "9f2c1ab", platform: "web",
      environment: "staging" },
    { async send(bundle) { shipped = bundle; } });

  session.add({
    id: uuid(),
    comment: "clearing the search leaves the old results on screen",
    tag: "bug",
    capturedAt: new Date().toISOString(),
    screen: "/search",
    viewport: { x: 0, y: 0, width: 1280, height: 800 },
    element: {
      accessibilityID: "search.results",
      label: "Search results",
      className: "ul",
      selector: 'ul[data-testid="search.results"]',
      bounds: { x: 16, y: 120, width: 992, height: 540 },
    },
    trace: [{
      method: "GET", url: "https://api.acme.test/v2/search?q=",
      statusCode: 500, durationMs: 88, at: new Date().toISOString(),
    }],
    logs: [{
      level: "error", message: "kept the last good page after a 500",
      subsystem: "search", at: new Date().toISOString(),
    }],
    // Four bytes of PNG magic is enough to prove the field carries base64.
    screenshotPNG: "iVBORw==",
  });

  await session.send();
  assert.ok(shipped, "nothing was sent");
  check(shipped);
  assert.equal(shipped!.formatVersion, CURRENT_FORMAT_VERSION);
  assert.equal(shipped!.app.platform, "web");
});

test("the minimum a bundle can carry still validates", async () => {
  let shipped: AnnotationBundle | undefined;
  const session = new AnnotationSession(
    { name: "Bare", platform: "electron" },
    { async send(bundle) { shipped = bundle; } });

  session.add({
    id: uuid(),
    comment: "this",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  });
  await session.send();
  check(shipped);
});

test("uuid is v4-shaped even without crypto.randomUUID", () => {
  const original = globalThis.crypto.randomUUID;
  // Plain http:// on a LAN address, which is what staging often is.
  Object.defineProperty(globalThis.crypto, "randomUUID", { value: undefined, configurable: true });
  try {
    const id = uuid();
    assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  } finally {
    Object.defineProperty(globalThis.crypto, "randomUUID", { value: original, configurable: true });
  }
});

test("the generated tokens still match docs/tokens.json", async () => {
  const { tokens } = await import("../src/tokens.generated.js");
  const source = JSON.parse(readFileSync(join(docs, "tokens.json"), "utf8"));
  delete source.$comment;
  assert.deepEqual(JSON.parse(JSON.stringify(tokens)), source,
    "run `npm run sync-tokens` - a token must not mean two things on two platforms");
});
