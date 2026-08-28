import type { LogEvent, LogLevel, NetworkEvent } from "./types.js";

/**
 * A ring buffer of recent requests, kept from page load.
 *
 * This is the linkage that makes an annotation useful: it pins which endpoints the
 * screen actually called, instead of leaving the agent to guess from static code.
 */
export class NetworkRecorder {
  private events: NetworkEvent[] = [];
  private uninstall?: () => void;
  private readonly capacity: number;

  constructor(capacity = 200) {
    this.capacity = capacity;
  }

  record(event: NetworkEvent): void {
    this.events.push(event);
    if (this.events.length > this.capacity) {
      this.events.splice(0, this.events.length - this.capacity);
    }
  }

  /**
   * Everything in the last `windowMs`, oldest first. A short window keeps unrelated
   * background polling out of the ticket.
   */
  recent(windowMs = 30_000, now = Date.now()): NetworkEvent[] {
    const cutoff = now - windowMs;
    return this.events.filter((e) => Date.parse(e.at) >= cutoff);
  }

  clear(): void {
    this.events = [];
  }

  /**
   * Wraps `fetch` and `XMLHttpRequest`. Both, because plenty of staging apps still
   * carry an XHR-based client somewhere in a dependency, and a trace that silently
   * misses those is worse than no trace: it reads as "the screen made no calls".
   */
  install(target: Window & typeof globalThis): void {
    if (this.uninstall) return;

    const originalFetch = target.fetch?.bind(target);
    const OriginalXHR = target.XMLHttpRequest;
    const recorder = this;

    if (originalFetch) {
      target.fetch = async function (input: RequestInfo | URL, init?: RequestInit) {
        const startedAt = new Date().toISOString();
        const started = Date.now();
        const method = init?.method
          ?? (typeof input === "object" && "method" in input ? input.method : "GET");
        const url = typeof input === "string" ? input
          : input instanceof URL ? input.href
          : input.url;
        try {
          const response = await originalFetch(input, init);
          recorder.record({
            method: method ?? "GET", url,
            statusCode: response.status,
            durationMs: Date.now() - started, at: startedAt,
          });
          return response;
        } catch (error) {
          // A request that never completed still tells the agent something, and it
          // is usually the most interesting line in the trace.
          recorder.record({
            method: method ?? "GET", url,
            statusCode: null,
            durationMs: Date.now() - started, at: startedAt,
          });
          throw error;
        }
      };
    }

    if (OriginalXHR) {
      class RecordingXHR extends OriginalXHR {
        private loupeMethod = "GET";
        private loupeURL = "";
        private loupeStartedAt = "";
        private loupeStarted = 0;

        override open(method: string, url: string | URL, ...rest: unknown[]): void {
          this.loupeMethod = method;
          this.loupeURL = typeof url === "string" ? url : url.href;
          // @ts-expect-error the overload signatures differ across lib versions
          super.open(method, url, ...rest);
        }

        override send(body?: Document | XMLHttpRequestBodyInit | null): void {
          this.loupeStartedAt = new Date().toISOString();
          this.loupeStarted = Date.now();
          this.addEventListener("loadend", () => {
            recorder.record({
              method: this.loupeMethod,
              url: this.loupeURL,
              statusCode: this.status === 0 ? null : this.status,
              durationMs: Date.now() - this.loupeStarted,
              at: this.loupeStartedAt,
            });
          });
          super.send(body);
        }
      }
      target.XMLHttpRequest = RecordingXHR as unknown as typeof XMLHttpRequest;
    }

    this.uninstall = () => {
      if (originalFetch) target.fetch = originalFetch;
      if (OriginalXHR) target.XMLHttpRequest = OriginalXHR;
    };
  }

  stop(): void {
    this.uninstall?.();
    this.uninstall = undefined;
  }
}

/**
 * A ring buffer of log lines, in **two** lanes.
 *
 * Errors are the reason someone is annotating at all, so a burst of debug chatter
 * after the failure must never evict the failing line. Each lane is bounded, so
 * memory stays flat on a page left open all day.
 */
export class LogRecorder {
  private sequence = 0;
  private general: Array<{ seq: number; event: LogEvent }> = [];
  private errors: Array<{ seq: number; event: LogEvent }> = [];
  private uninstall?: () => void;
  private readonly capacity: number;

  constructor(capacity = 200) {
    this.capacity = capacity;
  }

  record(event: LogEvent): void {
    const entry = { seq: ++this.sequence, event };
    const lane = event.level === "error" ? this.errors : this.general;
    lane.push(entry);
    if (lane.length > this.capacity) lane.splice(0, lane.length - this.capacity);
  }

  debug(message: string, subsystem?: string) { this.log("debug", message, subsystem); }
  info(message: string, subsystem?: string) { this.log("info", message, subsystem); }
  warning(message: string, subsystem?: string) { this.log("warning", message, subsystem); }
  error(message: string, subsystem?: string) { this.log("error", message, subsystem); }

  private log(level: LogLevel, message: string, subsystem?: string): void {
    const event: LogEvent = { level, message, at: new Date().toISOString() };
    if (subsystem) event.subsystem = subsystem;
    this.record(event);
  }

  /** In the order the page produced them, not in wall-clock order. */
  recent(windowMs = 30_000, now = Date.now()): LogEvent[] {
    const cutoff = now - windowMs;
    return [...this.general, ...this.errors]
      .filter((e) => Date.parse(e.event.at) >= cutoff)
      .sort((a, b) => a.seq - b.seq)
      .map((e) => e.event);
  }

  clear(): void {
    this.general = [];
    this.errors = [];
    this.sequence = 0;
  }

  /**
   * Opt-in console capture, plus unhandled errors.
   *
   * Off by default. Console output on a real page carries whatever the app decided
   * to print, and quietly shipping all of it to an intake endpoint is not a decision
   * an SDK gets to make for its host.
   */
  install(target: Window & typeof globalThis, options: { console?: boolean } = {}): void {
    if (this.uninstall) return;
    const undo: Array<() => void> = [];

    if (options.console && target.console) {
      const levels: Array<[keyof Console, LogLevel]> = [
        ["log", "info"], ["info", "info"], ["warn", "warning"], ["error", "error"],
      ];
      for (const [name, level] of levels) {
        const original = target.console[name] as (...args: unknown[]) => void;
        if (typeof original !== "function") continue;
        (target.console as unknown as Record<string, unknown>)[name] = (...args: unknown[]) => {
          this.record({ level, message: args.map(stringify).join(" "),
                        subsystem: "console", at: new Date().toISOString() });
          original.apply(target.console, args);
        };
        undo.push(() => { (target.console as unknown as Record<string, unknown>)[name] = original; });
      }
    }

    const onError = (event: ErrorEvent) => {
      this.error(event.message || String(event.error), "window");
    };
    const onRejection = (event: PromiseRejectionEvent) => {
      this.error(`unhandled rejection: ${stringify(event.reason)}`, "window");
    };
    target.addEventListener("error", onError);
    target.addEventListener("unhandledrejection", onRejection as EventListener);
    undo.push(() => {
      target.removeEventListener("error", onError);
      target.removeEventListener("unhandledrejection", onRejection as EventListener);
    });

    this.uninstall = () => undo.forEach((f) => f());
  }

  stop(): void {
    this.uninstall?.();
    this.uninstall = undefined;
  }
}

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  if (value instanceof Error) return `${value.name}: ${value.message}`;
  try {
    return JSON.stringify(value) ?? String(value);
  } catch {
    return String(value);
  }
}
