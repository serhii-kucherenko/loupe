import { test } from "node:test";
import assert from "node:assert/strict";

import {
  LEAST_USEFUL_AREA, isUsablePath, pathArea, pathBounds, pathRef, simplifyPath,
} from "../src/picker.js";
import type { PathPoint } from "../src/types.js";

const viewport = { width: 1000, height: 800 };

function line(from: PathPoint, to: PathPoint, steps: number): PathPoint[] {
  return Array.from({ length: steps + 1 }, (_, i): PathPoint => {
    const t = i / steps;
    return [from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t];
  });
}

function circle(cx: number, cy: number, r: number, n: number): PathPoint[] {
  return Array.from({ length: n }, (_, i): PathPoint => {
    const a = (2 * Math.PI * i) / n;
    return [cx + r * Math.cos(a), cy + r * Math.sin(a)];
  });
}

// MARK: - Thinning

test("a straight run collapses to its ends", () => {
  const drawn = line([0, 0], [300, 0], 200);
  const kept = simplifyPath(drawn);
  assert.equal(kept.length, 2, "201 points on one line say nothing 2 do not");
  assert.deepEqual(kept[0], drawn[0]);
  assert.deepEqual(kept[kept.length - 1], drawn[drawn.length - 1]);
});

test("a corner survives", () => {
  const kept = simplifyPath([...line([0, 0], [0, 100], 50),
                             ...line([0, 100], [100, 100], 50).slice(1)]);
  assert.equal(kept.length, 3, "two ends and the corner between them");
  assert.ok(kept.some(([x, y]) => x === 0 && y === 100), "the corner is the shape");
});

test("a hand-drawn shape loses points and keeps its shape", () => {
  const drawn = circle(200, 200, 80, 400);
  const kept = simplifyPath(drawn);

  assert.ok(kept.length < drawn.length / 4, "most of those points were noise");
  assert.ok(kept.length > 8, "and it is still recognisably a circle");

  const before = pathBounds(drawn);
  const after = pathBounds(kept);
  assert.ok(Math.abs(after.width - before.width) < 4);
  assert.ok(Math.abs(after.height - before.height) < 4);
});

/**
 * A closed shape ends where it started, so the line through its two ends has no
 * length and the usual distance formula divides by zero. It is the normal case here.
 */
test("a shape that ends where it started is not thrown away", () => {
  const drawn = circle(100, 100, 40, 80);
  const kept = simplifyPath([...drawn, drawn[0] as PathPoint]);
  assert.ok(kept.length > 6);
  assert.ok(kept.every(([x, y]) => Number.isFinite(x) && Number.isFinite(y)));
});

// MARK: - Telling a shape from a slipped pointer

/**
 * The one every single-segment gesture produces, and therefore most accidents. Its
 * bounding box is hundreds of pixels wide and it encloses nothing at all, so any box
 * measure calls it a fine shape.
 */
test("a straight swipe encloses nothing and is not a shape", () => {
  assert.equal(isUsablePath(line([40, 300], [340, 300], 30)), false);
  assert.equal(isUsablePath(line([0, 0], [200, 200], 30)), false,
               "a diagonal has a big box and no inside either");
});

test("a pointer that slipped is not a shape", () => {
  assert.equal(isUsablePath([[100, 100], [103, 101], [104, 104]]), false);
  assert.equal(isUsablePath([[0, 0], [200, 200]]), false, "two points are never a shape");
});

test("the area is the same whichever way round it was drawn", () => {
  const square: PathPoint[] = [[0, 0], [100, 0], [100, 50], [0, 50]];
  assert.equal(pathArea(square), 5000);
  assert.equal(pathArea([...square].reverse()), 5000);
  assert.ok(pathArea(square) >= LEAST_USEFUL_AREA);
});

// MARK: - What ends up in the note

test("a shape becomes a path reference with its box as bounds", () => {
  const ref = pathRef([[10, 20], [90, 20], [90, 80], [10, 80]], viewport);
  assert.ok(ref);
  assert.equal(ref.kind, "path");
  assert.deepEqual(ref.bounds, { x: 10, y: 20, width: 80, height: 60 },
                   "a reader that ignores the path gets the rectangle it expects");
  assert.equal(ref.path?.length, 4);
});

test("a shape drawn off the edge is clipped to the viewport", () => {
  const ref = pathRef([[-50, -50], [1200, -20], [1200, 900], [-50, 900]], viewport);
  assert.ok(ref);
  assert.deepEqual(ref.bounds, { x: 0, y: 0, width: 1000, height: 800 });
});

test("a gesture that encloses nothing yields no reference at all", () => {
  assert.equal(pathRef(line([0, 400], [900, 400], 40), viewport), null,
               "so the caller can fall back to a click rather than file a blank note");
});

/**
 * The contract every field added since v1 follows: ignore `path` and you still get
 * the rectangle a drag would have given you.
 */
test("the bounds are usable on their own", () => {
  const ref = pathRef(circle(300, 300, 60, 40), viewport);
  assert.ok(ref);
  assert.ok(ref.bounds.width > 100 && ref.bounds.height > 100);
  assert.equal(ref.selector, undefined, "a shape has no element, and says so");
});
