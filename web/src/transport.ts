import type { AnnotationBundle } from "./types.js";

export interface Transport {
  send(bundle: AnnotationBundle): Promise<void>;
}

/** POSTs the bundle to a triage endpoint. */
export class HTTPTransport implements Transport {
  private readonly endpoint: string;
  private readonly headers: Record<string, string>;

  constructor(endpoint: string, headers: Record<string, string> = {}) {
    this.endpoint = endpoint;
    this.headers = headers;
  }

  async send(bundle: AnnotationBundle): Promise<void> {
    const response = await fetch(this.endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json", ...this.headers },
      body: JSON.stringify(bundle),
    });
    if (!response.ok) {
      throw new Error(`triage returned ${response.status}`);
    }
  }
}

/**
 * Persist-then-send wrapper around any other transport.
 *
 * Without it, a failed send survives only while the tab is open, and closing a tab
 * is not a deliberate act the way quitting an app is. Every bundle hits storage
 * before the network is tried; a success clears it, a failure leaves it for `drain`.
 *
 * Nothing is held in memory, so a reload finds whatever the last page could not
 * deliver.
 */
export class QueuedTransport implements Transport {
  static readonly PREFIX = "loupe:queue:";

  private readonly inner: Transport;
  private readonly storage: Storage;

  constructor(inner: Transport, storage: Storage) {
    this.inner = inner;
    this.storage = storage;
  }

  get pendingCount(): number {
    return this.keys().length;
  }

  async send(bundle: AnnotationBundle): Promise<void> {
    const key = this.persist(bundle);
    // No try/catch: if the send throws, the key is simply still there, which is
    // exactly what `drain` is looking for.
    await this.inner.send(bundle);
    if (key) this.storage.removeItem(key);
  }

  /**
   * Ship everything waiting, oldest first, stopping at the first failure.
   *
   * Stopping rather than skipping ahead: a backlog delivered out of order would
   * reorder someone's annotations, and a network that just failed will almost
   * certainly fail on the next one too.
   */
  async drain(): Promise<void> {
    for (const key of this.keys()) {
      const raw = this.storage.getItem(key);
      if (!raw) continue;
      let bundle: AnnotationBundle;
      try {
        bundle = JSON.parse(raw) as AnnotationBundle;
      } catch {
        // Unreadable is unrecoverable. Keeping it would block the queue forever.
        this.storage.removeItem(key);
        continue;
      }
      await this.inner.send(bundle);
      this.storage.removeItem(key);
    }
  }

  /** Keeps trying while the network is still coming back. Doubling delay. */
  async drainWithRetry(attempts = 3, initialDelayMs = 1000): Promise<void> {
    let delay = initialDelayMs;
    for (let attempt = 1; attempt <= Math.max(1, attempts); attempt++) {
      try {
        await this.drain();
        return;
      } catch (error) {
        if (attempt >= attempts) throw error;
        await new Promise((resolve) => setTimeout(resolve, delay));
        delay *= 2;
      }
    }
  }

  /**
   * Fixed-width seconds keep the keys sortable as plain text, and the session id
   * keeps two bundles stamped in the same millisecond from colliding.
   *
   * Returns undefined when storage refused it. A full quota must not stop the send
   * that is about to happen anyway - losing the backup is survivable, losing the
   * annotation is not.
   */
  private persist(bundle: AnnotationBundle): string | undefined {
    const stamp = String(Date.parse(bundle.sentAt) || Date.now()).padStart(16, "0");
    const key = `${QueuedTransport.PREFIX}${stamp}-${bundle.sessionID}`;
    try {
      this.storage.setItem(key, JSON.stringify(bundle));
      return key;
    } catch {
      return undefined;
    }
  }

  private keys(): string[] {
    const found: string[] = [];
    for (let i = 0; i < this.storage.length; i++) {
      const key = this.storage.key(i);
      if (key?.startsWith(QueuedTransport.PREFIX)) found.push(key);
    }
    return found.sort();
  }
}
