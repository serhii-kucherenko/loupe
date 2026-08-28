import type { Annotation, AnnotationBundle, AnnotationTag, AppInfo } from "./types.js";
import { CURRENT_FORMAT_VERSION, uuid } from "./types.js";
import type { Transport } from "./transport.js";

/**
 * The tray. You enter annotate mode once, then pick and comment as many times as you
 * like. It survives navigation on purpose, so one session can span several screens -
 * which on the web includes a full page load, hence the write-through to storage on
 * every change.
 */
export class AnnotationSession {
  static readonly STORAGE_KEY = "loupe:tray";

  private readonly app: AppInfo;
  private readonly transport: Transport;
  private readonly storage: Storage | undefined;

  sessionID = uuid();
  annotations: Annotation[] = [];
  onChange?: () => void;

  constructor(app: AppInfo, transport: Transport, storage?: Storage) {
    this.app = app;
    this.transport = transport;
    this.storage = storage;
    this.restore();
  }

  get isEmpty(): boolean { return this.annotations.length === 0; }
  get count(): number { return this.annotations.length; }

  add(annotation: Annotation): void {
    this.annotations.push(annotation);
    this.changed();
  }

  remove(id: string): void {
    this.annotations = this.annotations.filter((a) => a.id !== id);
    this.changed();
  }

  updateComment(id: string, comment: string): void {
    const found = this.annotations.find((a) => a.id === id);
    if (!found) return;
    found.comment = comment;
    this.changed();
  }

  updateTag(id: string, tag: AnnotationTag | undefined): void {
    const found = this.annotations.find((a) => a.id === id);
    if (!found) return;
    if (tag) found.tag = tag; else delete found.tag;
    this.changed();
  }

  makeBundle(): AnnotationBundle {
    return {
      formatVersion: CURRENT_FORMAT_VERSION,
      sessionID: this.sessionID,
      app: this.app,
      annotations: this.annotations,
      sentAt: new Date().toISOString(),
    };
  }

  /** Ships the tray, and only clears it once the transport confirms. */
  async send(): Promise<AnnotationBundle> {
    if (this.isEmpty) throw new Error("nothing to send");
    const bundle = this.makeBundle();
    await this.transport.send(bundle);
    this.annotations = [];
    this.sessionID = uuid();
    this.changed();
    return bundle;
  }

  private changed(): void {
    this.save();
    this.onChange?.();
  }

  private save(): void {
    if (!this.storage) return;
    try {
      this.storage.setItem(AnnotationSession.STORAGE_KEY, JSON.stringify({
        sessionID: this.sessionID,
        annotations: this.annotations,
      }));
    } catch {
      // Losing the backup must never take the live tray with it.
    }
  }

  private restore(): void {
    if (!this.storage) return;
    const raw = this.storage.getItem(AnnotationSession.STORAGE_KEY);
    if (!raw) return;
    try {
      const saved = JSON.parse(raw) as { sessionID: string; annotations: Annotation[] };
      if (!Array.isArray(saved.annotations)) return;
      this.sessionID = saved.sessionID || this.sessionID;
      this.annotations = saved.annotations;
    } catch {
      // A tray we cannot read is a tray we do not have.
    }
  }
}
