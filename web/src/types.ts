/**
 * The bundle format, version 1.
 *
 * These types are the TypeScript half of `docs/bundle-format.md`. They are written
 * out rather than generated so that reading this file tells you the whole contract,
 * and `test/format.test.ts` holds them to the same JSON Schema the Swift SDK
 * is held to.
 */

export type AnnotationTag = "bug" | "idea" | "polish" | "question";
export type LogLevel = "debug" | "info" | "warning" | "error";

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/**
 * Where the annotation points. Everything but `bounds` is best-effort: the crop plus
 * the trace carry the meaning, so a missing field degrades quality, never correctness.
 */
/**
 * Whether the annotation is about a thing on the page or an area of it.
 *
 * A region is not a failed pick. Two controls misaligned with each other, the
 * padding around a group, the gap between two rows: none of those is an element.
 */
export type ElementKind = "view" | "region";

export interface ElementRef {
  /** Absent means `view`, so a bundle written before this existed still means what it meant. */
  kind?: ElementKind;
  accessibilityID?: string;
  label?: string;
  className?: string;
  /** A CSS selector that finds the element again. Web and Electron only. */
  selector?: string;
  sourceFile?: string;
  sourceLine?: number;
  /** In viewport coordinates, top-left origin. */
  bounds: Rect;
}

export interface NetworkEvent {
  method: string;
  url: string;
  statusCode: number | null;
  durationMs: number;
  /** ISO-8601. When the request *started*. */
  at: string;
}

export interface LogEvent {
  level: LogLevel;
  message: string;
  subsystem?: string;
  at: string;
}

export interface Annotation {
  id: string;
  comment: string;
  tag?: AnnotationTag;
  element: ElementRef;
  /** base64 PNG of the element. Absent when no picture could be taken; see `capture.ts`. */
  screenshotPNG?: string;
  /**
   * base64 PNG of the whole window with the element outlined.
   *
   * Apple platforms only. The browser has no way to photograph a page it is
   * rendering, and the `foreignObject` route used for the crop does not scale to a
   * whole document. Declared here so a consumer written against these types can read
   * an Apple bundle.
   */
  contextScreenshotPNG?: string;
  trace?: NetworkEvent[];
  logs?: LogEvent[];
  screen?: string;
  viewport?: Rect;
  capturedAt: string;
}

export interface AppInfo {
  name: string;
  version?: string;
  /** The most useful field here: it is how an agent checks out the right code. */
  commitSHA?: string;
  /** `web` or `electron` from this SDK. */
  platform: string;
  environment?: string;
  /** Which screen this was captured on. Filled in by `start`. */
  device?: DeviceInfo;
}

/**
 * The machine a note was taken on, as far as a layout bug needs.
 *
 * **Nothing identifying, ever.** No user agent string, no locale, no timezone, no
 * anything a fingerprinter would want. A bundle gets pasted into tickets and public
 * repositories; the moment it carries something a person would not want there, it
 * stops being safe to share, and that costs far more than any field here is worth.
 *
 * The browser has no non-identifying way to say which machine it is on, so
 * `identifier`, `name` and `osVersion` are Apple-only and simply absent here. Parsing
 * a user agent for them would be guessing *and* fingerprinting at the same time.
 */
export interface DeviceInfo {
  /** Apple platforms only, e.g. `iPad8,3`. */
  identifier?: string;
  /** Apple platforms only, e.g. `iPad Pro 11-inch`. */
  name?: string;
  /** Apple platforms only. The platform's own name is already on `AppInfo`. */
  osVersion?: string;
  /** The whole screen. `viewport` is the window, which is usually smaller. */
  screen?: { width: number; height: number; scale: number };
}

export interface AnnotationBundle {
  formatVersion: number;
  sessionID: string;
  app: AppInfo;
  annotations: Annotation[];
  sentAt: string;
}

export const CURRENT_FORMAT_VERSION = 1;

/** Crypto-quality where available, and still unique where it is not. */
export function uuid(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // http:// on a LAN address has no crypto.randomUUID, and staging often is exactly
  // that. A v4-shaped fallback keeps the id valid rather than throwing.
  const bytes = new Uint8Array(16);
  for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
  bytes[6] = (bytes[6]! & 0x0f) | 0x40;
  bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
