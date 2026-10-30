import { DOMException } from "./errors";

type Listener = ((event: Event) => void) | { handleEvent(event: Event): void };

interface Registration {
  listener: Listener;
  once: boolean;
  remove?: () => void;
}

export class Event {
  readonly type: string;
  readonly bubbles: boolean;
  readonly cancelable: boolean;
  readonly composed: boolean;
  readonly timeStamp = Date.now();
  readonly isTrusted = false;
  target: EventTarget | null = null;
  currentTarget: EventTarget | null = null;
  defaultPrevented = false;
  #stopped = false;

  constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean; composed?: boolean } = {}) {
    if (arguments.length === 0) {
      throw new TypeError("Event needs a type");
    }
    this.type = String(type);
    this.bubbles = Boolean(init.bubbles);
    this.cancelable = Boolean(init.cancelable);
    this.composed = Boolean(init.composed);
  }

  preventDefault(): void {
    if (this.cancelable) {
      this.defaultPrevented = true;
    }
  }

  stopPropagation(): void {}

  stopImmediatePropagation(): void {
    this.#stopped = true;
  }

  get stopped(): boolean {
    return this.#stopped;
  }
}

export class CustomEvent<T = unknown> extends Event {
  readonly detail: T | null;

  constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean; composed?: boolean; detail?: T } = {}) {
    super(type, init);
    this.detail = init.detail ?? null;
  }
}

export class EventTarget {
  #listeners = new Map<string, Registration[]>();

  addEventListener(type: string, listener: Listener | null, options?: boolean | { once?: boolean; signal?: AbortSignal; capture?: boolean }): void {
    if (listener === null || listener === undefined) {
      return;
    }
    const { once = false, signal } = typeof options === "object" && options !== null ? options : {};
    if (signal?.aborted) {
      return;
    }
    const registrations = this.#listeners.get(type) ?? [];
    if (registrations.some(item => item.listener === listener)) {
      return;
    }
    const registration: Registration = { listener, once };
    if (signal) {
      const remove = () => this.removeEventListener(type, listener);
      signal.addEventListener("abort", remove, { once: true });
      registration.remove = () => signal.removeEventListener("abort", remove);
    }
    registrations.push(registration);
    this.#listeners.set(type, registrations);
  }

  removeEventListener(type: string, listener: Listener | null): void {
    const registrations = this.#listeners.get(type);
    const index = registrations?.findIndex(item => item.listener === listener) ?? -1;
    if (registrations && index >= 0) {
      registrations[index].remove?.();
      registrations.splice(index, 1);
    }
  }

  dispatchEvent(event: Event): boolean {
    event.target = this;
    event.currentTarget = this;
    const handler = (this as unknown as Record<string, unknown>)[`on${event.type}`];
    const registrations = [...(this.#listeners.get(event.type) ?? [])];
    const listeners: Listener[] = registrations.map(item => item.listener);
    if (typeof handler === "function") {
      listeners.unshift(handler as Listener);
    }
    for (const listener of listeners) {
      const registration = registrations.find(item => item.listener === listener);
      if (registration?.once) {
        this.removeEventListener(event.type, listener);
      }
      try {
        if (typeof listener === "function") {
          listener.call(this, event);
        } else {
          listener.handleEvent(event);
        }
      } catch (error) {
        queueMicrotask(() => {
          throw error;
        });
      }
      if (event.stopped) {
        break;
      }
    }
    event.currentTarget = null;
    return !event.defaultPrevented;
  }
}

const constructing = Symbol("AbortSignal");
let abortSignal: (signal: AbortSignal, reason: unknown) => void;

export class AbortSignal extends EventTarget {
  #aborted = false;
  #reason: unknown = undefined;
  onabort: ((event: Event) => void) | null = null;

  static {
    abortSignal = (signal, reason) => signal.#abort(reason);
  }

  constructor(key?: unknown) {
    if (key !== constructing) {
      throw new TypeError("Illegal constructor");
    }
    super();
  }

  static abort(reason?: unknown): AbortSignal {
    const controller = new AbortController();
    controller.abort(reason);
    return controller.signal;
  }

  static timeout(ms: number): AbortSignal {
    const controller = new AbortController();
    setTimeout(() => controller.abort(new DOMException("the operation timed out", "TimeoutError")), ms);
    return controller.signal;
  }

  static any(signals: Iterable<AbortSignal>): AbortSignal {
    const controller = new AbortController();
    const list = [...signals];
    const done = list.find(signal => signal.aborted);
    if (done) {
      controller.abort(done.reason);
      return controller.signal;
    }
    for (const signal of list) {
      signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true, signal: controller.signal });
    }
    return controller.signal;
  }

  get aborted(): boolean {
    return this.#aborted;
  }

  get reason(): unknown {
    return this.#reason;
  }

  throwIfAborted(): void {
    if (this.#aborted) {
      throw this.#reason;
    }
  }

  #abort(reason: unknown): void {
    if (this.#aborted) {
      return;
    }
    this.#aborted = true;
    this.#reason = reason === undefined ? new DOMException("the operation was aborted", "AbortError") : reason;
    this.dispatchEvent(new Event("abort"));
  }
}

export class AbortController {
  readonly signal = new AbortSignal(constructing);

  abort(reason?: unknown): void {
    abortSignal(this.signal, reason);
  }
}
