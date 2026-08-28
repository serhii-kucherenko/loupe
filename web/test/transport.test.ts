import { test } from "node:test";
import assert from "node:assert/strict";

import { QueuedTransport, type Transport } from "../src/transport.js";
import { AnnotationSession } from "../src/session.js";
import type { AnnotationBundle } from "../src/types.js";

/** The smallest thing that behaves like localStorage, plus a switch for a full disk. */
class MemoryStorage implements Storage {
  private map = new Map<string, string>();
  full = false;

  get length() { return this.map.size; }
  key(i: number) { return [...this.map.keys()][i] ?? null; }
  getItem(k: string) { return this.map.get(k) ?? null; }
  setItem(k: string, v: string) {
    if (this.full) throw new DOMException("quota", "QuotaExceededError");
    this.map.set(k, v);
  }
  removeItem(k: string) { this.map.delete(k); }
  clear() { this.map.clear(); }
  [name: string]: unknown;
}

class Flaky implements Transport {
  shouldFail = false;
  sent: AnnotationBundle[] = [];
  async send(bundle: AnnotationBundle) {
    if (this.shouldFail) throw new Error("offline");
    this.sent.push(bundle);
  }
}

function bundle(comment: string, sentAt = new Date().toISOString()): AnnotationBundle {
  return {
    formatVersion: 1,
    sessionID: crypto.randomUUID(),
    app: { name: "Demo", platform: "web" },
    sentAt,
    annotations: [{
      id: crypto.randomUUID(),
      comment,
      capturedAt: sentAt,
      element: { bounds: { x: 0, y: 0, width: 10, height: 10 } },
    }],
  };
}

test("a successful send leaves nothing pending", async () => {
  const inner = new Flaky();
  const queue = new QueuedTransport(inner, new MemoryStorage());
  await queue.send(bundle("goes straight out"));
  assert.equal(inner.sent.length, 1);
  assert.equal(queue.pendingCount, 0);
});

test("a failed send keeps the bundle and rethrows", async () => {
  const inner = new Flaky();
  inner.shouldFail = true;
  const queue = new QueuedTransport(inner, new MemoryStorage());

  await assert.rejects(() => queue.send(bundle("survives a reload")));
  assert.equal(queue.pendingCount, 1);
});

test("a backlog survives the page being closed", async () => {
  const storage = new MemoryStorage();
  const offline = new Flaky();
  offline.shouldFail = true;
  await assert.rejects(() =>
    new QueuedTransport(offline, storage).send(bundle("written before the reload")));

  // A new page, the same storage.
  const online = new Flaky();
  const afterReload = new QueuedTransport(online, storage);
  assert.equal(afterReload.pendingCount, 1);

  await afterReload.drain();
  assert.deepEqual(online.sent.map((b) => b.annotations[0]!.comment),
    ["written before the reload"]);
  assert.equal(afterReload.pendingCount, 0);
});

test("the backlog drains oldest first", async () => {
  const inner = new Flaky();
  inner.shouldFail = true;
  const queue = new QueuedTransport(inner, new MemoryStorage());
  const base = Date.parse("2026-08-28T09:00:00Z");

  for (const [i, name] of ["oldest", "middle", "newest"].entries()) {
    await queue.send(bundle(name, new Date(base + i * 60_000).toISOString()))
      .catch(() => {});
  }

  inner.shouldFail = false;
  await queue.drain();
  assert.deepEqual(inner.sent.map((b) => b.annotations[0]!.comment),
    ["oldest", "middle", "newest"]);
});

test("a failed drain stops rather than reordering, and drops nothing", async () => {
  const inner = new Flaky();
  inner.shouldFail = true;
  const queue = new QueuedTransport(inner, new MemoryStorage());
  await queue.send(bundle("a")).catch(() => {});
  await queue.send(bundle("b")).catch(() => {});

  await assert.rejects(() => queue.drain());
  assert.equal(queue.pendingCount, 2);
});

test("unreadable storage is discarded rather than blocking the queue forever", async () => {
  const storage = new MemoryStorage();
  storage.setItem(`${QueuedTransport.PREFIX}0000000000000001-x`, "{ not json");
  const inner = new Flaky();
  const queue = new QueuedTransport(inner, storage);

  await queue.drain();
  assert.equal(queue.pendingCount, 0);
  assert.equal(inner.sent.length, 0);
});

test("a full disk must not stop the send that is about to happen", async () => {
  const storage = new MemoryStorage();
  storage.full = true;
  const inner = new Flaky();
  const queue = new QueuedTransport(inner, storage);

  // Losing the backup is survivable. Losing the annotation is not.
  await queue.send(bundle("still goes out"));
  assert.equal(inner.sent.length, 1);
});

test("the tray is written on every change and restored on the next page", () => {
  const storage = new MemoryStorage();
  const app = { name: "Demo", platform: "web" };
  const annotation = {
    id: crypto.randomUUID(),
    comment: "typed before the reload",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  };

  const first = new AnnotationSession(app, new Flaky(), storage);
  first.add(annotation);

  const afterReload = new AnnotationSession(app, new Flaky(), storage);
  assert.deepEqual(afterReload.annotations.map((a) => a.comment), ["typed before the reload"]);
  assert.equal(afterReload.sessionID, first.sessionID, "one tray stays one bundle");
});

test("a successful send clears the saved tray", async () => {
  const storage = new MemoryStorage();
  const app = { name: "Demo", platform: "web" };
  const session = new AnnotationSession(app, new Flaky(), storage);
  session.add({
    id: crypto.randomUUID(), comment: "goes out",
    capturedAt: new Date().toISOString(),
    element: { bounds: { x: 0, y: 0, width: 1, height: 1 } },
  });

  await session.send();
  assert.equal(new AnnotationSession(app, new Flaky(), storage).count, 0);
});
