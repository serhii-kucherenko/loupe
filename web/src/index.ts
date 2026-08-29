import type { AppInfo } from "./types.js";
import { AnnotationSession } from "./session.js";
import { HTTPTransport, QueuedTransport, type Transport } from "./transport.js";
import { LogRecorder, NetworkRecorder } from "./recorder.js";
import { Overlay, type OverlayOptions } from "./overlay.js";
import type { Theme } from "./tokens.js";

export * from "./types.js";
export { AnnotationSession } from "./session.js";
export { HTTPTransport, QueuedTransport, type Transport } from "./transport.js";
export { LogRecorder, NetworkRecorder } from "./recorder.js";
export { Overlay, swallowsInput, type OverlayMode } from "./overlay.js";
export { screenshotPNG } from "./capture.js";
export { pick, elementRef, meaningfulAncestor, cssSelector } from "./picker.js";
export { tokens, cssVariables } from "./tokens.js";
export type { Theme, ThemeColour } from "./tokens.js";

export interface StartOptions {
  app: AppInfo;
  /** Where bundles go. A URL is wrapped in an HTTP transport for you. */
  endpoint?: string;
  transport?: Transport;
  headers?: Record<string, string>;
  /** Capture `console.*` as well as unhandled errors. Off by default: see below. */
  captureConsole?: boolean;
  captureScreenshots?: boolean;
  screen?: () => string;
  window?: Window & typeof globalThis;
  /**
   * Your own design tokens, so the overlay stops looking like a visitor:
   *
   *     start({ app, theme: { accent: "var(--brand)", panelRadius: 28 } })
   *
   * The overlay lives in a shadow root, so your page's stylesheet cannot reach in -
   * this is the way through. Every field is optional; omit it and nothing changes.
   */
  theme?: Theme;
}

/**
 * The entry point a web app uses. One call, in dev and staging builds only:
 *
 *     import { start } from "@loupe/web";
 *     start({ app: { name: "Acme", platform: "web" }, endpoint: "/loupe/intake" });
 *
 * After that ⌥⌘L (Alt+Ctrl+L off a Mac) opens annotate mode. Nothing else in the
 * host app has to know Loupe is there.
 *
 * Console capture is off unless you ask for it. Console output carries whatever the
 * app decided to print, and quietly shipping all of it to an intake endpoint is not
 * a decision an SDK gets to make on its host's behalf.
 */
export function start(options: StartOptions): Loupe {
  const view = options.window ?? (globalThis as unknown as Window & typeof globalThis);

  const network = new NetworkRecorder();
  const logs = new LogRecorder();
  network.install(view);
  logs.install(view, { console: options.captureConsole ?? false });

  const storage = safeStorage(view);
  const base: Transport = options.transport
    ?? new HTTPTransport(options.endpoint ?? "/loupe/intake", options.headers);
  const queue = storage ? new QueuedTransport(base, storage) : undefined;

  const session = new AnnotationSession(options.app, queue ?? base, storage);

  const overlayOptions: OverlayOptions = {
    network, logs,
    captureScreenshots: options.captureScreenshots ?? true,
  };
  if (options.theme) overlayOptions.theme = options.theme;
  if (queue) overlayOptions.queue = queue;
  if (options.screen) overlayOptions.screen = options.screen;

  const overlay = new Overlay(session, view, overlayOptions);

  // Anything left from a previous page load goes out as soon as there is a network.
  void queue?.drainWithRetry().catch(() => { /* the tray still holds it */ });

  return { session, overlay, network, logs, queue, stop: () => {
    overlay.destroy();
    network.stop();
    logs.stop();
  } };
}

export interface Loupe {
  session: AnnotationSession;
  overlay: Overlay;
  network: NetworkRecorder;
  logs: LogRecorder;
  queue?: QueuedTransport;
  stop(): void;
}

/**
 * `localStorage` throws rather than returning null in a sandboxed iframe or with
 * cookies blocked, and losing the offline queue must never stop Loupe from working.
 */
function safeStorage(view: Window): Storage | undefined {
  try {
    const storage = view.localStorage;
    const probe = "loupe:probe";
    storage.setItem(probe, "1");
    storage.removeItem(probe);
    return storage;
  } catch {
    return undefined;
  }
}
