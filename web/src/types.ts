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
export interface ElementRef {
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
  /** base64 PNG. Absent when no picture could be taken; see `capture.ts`. */
  screenshotPNG?: string;
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
