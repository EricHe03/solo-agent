import { DOMException } from "./errors";

type Listener = ((event: Event) => void) | { handleEvent(event: Event): void };
type Handler = ((event: Event) => unknown) | null;

interface Registration {
  listener: Listener;
  once: boolean;
  removed: boolean;
  remove?: () => void;
}

let trust: (event: Event) => Event;
let beginDispatch: (event: Event, target: EventTarget) => void;
let endDispatch: (event: Event) => void;
let immediatelyStopped: (event: Event) => boolean;

export class Event {
  static readonly NONE = 0;
  static readonly CAPTURING_PHASE = 1;
  static readonly AT_TARGET = 2;
  static readonly BUBBLING_PHASE = 3;
  readonly NONE = 0;
  readonly CAPTURING_PHASE = 1;
  readonly AT_TARGET = 2;
  readonly BUBBLING_PHASE = 3;

  readonly type: string;
  readonly bubbles: boolean;
  readonly cancelable: boolean;
  readonly composed: boolean;
  readonly timeStamp = Date.now();
  #trusted = false;
  #target: EventTarget | null = null;
  #dispatching = false;
  #canceled = false;
  #propagationStopped = false;
  #immediateStopped = false;

  static {
    trust = event => {
      event.#trusted = true;
      return event;
    };
    beginDispatch = (event, target) => {
      if (event.#dispatching) {
        throw new DOMException("the event is already being dispatched", "InvalidStateError");
      }
      event.#dispatching = true;
      event.#target = target;
    };
    endDispatch = event => {
      event.#dispatching = false;
      event.#propagationStopped = false;
      event.#immediateStopped = false;
    };
    immediatelyStopped = event => event.#immediateStopped;
  }

  constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean; composed?: boolean } = {}) {
    if (arguments.length === 0) {
      throw new TypeError("Event needs a type");
    }
    this.type = String(type);
    this.bubbles = Boolean(init?.bubbles);
    this.cancelable = Boolean(init?.cancelable);
    this.composed = Boolean(init?.composed);
  }

  get isTrusted(): boolean {
    return this.#trusted;
  }

  get target(): EventTarget | null {
    return this.#target;
  }

  get srcElement(): EventTarget | null {
    return this.#target;
  }

  get currentTarget(): EventTarget | null {
    return this.#dispatching ? this.#target : null;
  }

  get eventPhase(): number {
    return this.#dispatching ? Event.AT_TARGET : Event.NONE;
  }

  get defaultPrevented(): boolean {
    return this.#canceled;
  }

  get returnValue(): boolean {
    return !this.#canceled;
  }

  set returnValue(value: boolean) {
    if (!value) {
      this.preventDefault();
    }
  }

  get cancelBubble(): boolean {
    return this.#propagationStopped;
  }

  set cancelBubble(value: boolean) {
    if (value) {
      this.#propagationStopped = true;
    }
  }

  composedPath(): EventTarget[] {
    return this.#dispatching && this.#target !== null ? [this.#target] : [];
  }

  preventDefault(): void {
    if (this.cancelable) {
      this.#canceled = true;
    }
  }

  stopPropagation(): void {
    this.#propagationStopped = true;
  }

  stopImmediatePropagation(): void {
    this.#propagationStopped = true;
    this.#immediateStopped = true;
  }

  get [Symbol.toStringTag](): string {
    return "Event";
  }
}

export { trust };

export class CustomEvent<T = unknown> extends Event {
  readonly detail: T | null;

  constructor(type: string, init: { bubbles?: boolean; cancelable?: boolean; composed?: boolean; detail?: T } = {}) {
    super(type, init);
    this.detail = init?.detail ?? null;
  }
}

interface EventInit {
  bubbles?: boolean;
  cancelable?: boolean;
  composed?: boolean;
}

export class MessageEvent<T = unknown> extends Event {
  readonly data: T;
  readonly origin: string;
  readonly lastEventId: string;
  readonly source = null;
  readonly ports: readonly never[] = Object.freeze([]);

  constructor(type: string, init: EventInit & { data?: T; origin?: string; lastEventId?: string } = {}) {
    super(type, init);
    this.data = init.data as T;
    this.origin = String(init.origin ?? "");
    this.lastEventId = String(init.lastEventId ?? "");
  }
}

export class CloseEvent extends Event {
  readonly code: number;
  readonly reason: string;
  readonly wasClean: boolean;

  constructor(type: string, init: EventInit & { code?: number; reason?: string; wasClean?: boolean } = {}) {
    super(type, init);
    this.code = Number(init.code ?? 0);
    this.reason = String(init.reason ?? "");
    this.wasClean = Boolean(init.wasClean);
  }
}

export class ErrorEvent extends Event {
  readonly message: string;
  readonly error: unknown;
  readonly filename = "";
  readonly lineno = 0;
  readonly colno = 0;

  constructor(type: string, init: EventInit & { message?: string; error?: unknown } = {}) {
    super(type, init);
    this.message = String(init.message ?? "");
    this.error = init.error;
  }
}

let handlerOf: (target: EventTarget, type: string) => Handler;
let setHandler: (target: EventTarget, type: string, value: unknown) => void;

export class EventTarget {
  #listeners = new Map<string, Registration[]>();
  #handlers = new Map<string, { value: Handler; listener: Listener }>();

  static {
    handlerOf = (target, type) => target.#handlers.get(type)?.value ?? null;
    setHandler = (target, type, value) => {
      const handler = typeof value === "function" ? value as Handler : null;
      const slot = target.#handlers.get(type);
      if (slot !== undefined && handler !== null) {
        slot.value = handler;
        return;
      }
      if (slot !== undefined) {
        target.#handlers.delete(type);
        target.#remove(type, registration => registration.listener === slot.listener);
        return;
      }
      if (handler !== null) {
        const created: { value: Handler; listener: Listener } = {
          value: handler,
          listener(this: EventTarget, event: Event) {
            created.value?.call(this, event);
          },
        };
        target.#handlers.set(type, created);
        target.#add(type, { listener: created.listener, once: false, removed: false });
      }
    };
  }

  #add(type: string, registration: Registration): void {
    const registrations = this.#listeners.get(type) ?? [];
    registrations.push(registration);
    this.#listeners.set(type, registrations);
  }

  #remove(type: string, match: (registration: Registration) => boolean): void {
    const registrations = this.#listeners.get(type);
    const index = registrations?.findIndex(match) ?? -1;
    if (registrations && index >= 0) {
      const [registration] = registrations.splice(index, 1);
      registration.removed = true;
      registration.remove?.();
    }
  }

  addEventListener(type: string, listener: Listener | null, options?: boolean | { once?: boolean; signal?: AbortSignal; capture?: boolean; passive?: boolean }): void {
    if (listener === null || listener === undefined) {
      return;
    }
    const { once = false, signal } = typeof options === "object" && options !== null ? options : {};
    if (signal?.aborted) {
      return;
    }
    if (this.#listeners.get(type)?.some(item => item.listener === listener)) {
      return;
    }
    const registration: Registration = { listener, once: Boolean(once), removed: false };
    if (signal) {
      const remove = () => this.removeEventListener(type, listener);
      signal.addEventListener("abort", remove, { once: true });
      registration.remove = () => signal.removeEventListener("abort", remove);
    }
    this.#add(type, registration);
  }

  removeEventListener(type: string, listener: Listener | null): void {
    this.#remove(type, registration => registration.listener === listener);
  }

  dispatchEvent(event: Event): boolean {
    if (!(event instanceof Event)) {
      throw new TypeError("dispatchEvent takes an Event");
    }
    beginDispatch(event, this);
    try {
      for (const registration of [...(this.#listeners.get(event.type) ?? [])]) {
        if (registration.removed) {
          continue;
        }
        if (registration.once) {
          this.#remove(event.type, item => item === registration);
        }
        try {
          const { listener } = registration;
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
        if (immediatelyStopped(event)) {
          break;
        }
      }
    } finally {
      endDispatch(event);
    }
    return !event.defaultPrevented;
  }
}

export function eventHandlers(target: { prototype: EventTarget }, types: string[]): void {
  for (const type of types) {
    Object.defineProperty(target.prototype, `on${type}`, {
      get(this: EventTarget) {
        return handlerOf(this, type);
      },
      set(this: EventTarget, value: unknown) {
        setHandler(this, type, value);
      },
      enumerable: true,
      configurable: true,
    });
  }
}

const constructing = Symbol("AbortSignal");
let abortSignal: (signal: AbortSignal, reason: unknown) => void;

export class AbortSignal extends EventTarget {
  #aborted = false;
  #reason: unknown = undefined;
  declare onabort: ((event: Event) => void) | null;

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
    this.dispatchEvent(trust(new Event("abort")));
  }
}

eventHandlers(AbortSignal, ["abort"]);

export class AbortController {
  readonly signal = new AbortSignal(constructing);

  abort(reason?: unknown): void {
    abortSignal(this.signal, reason);
  }
}
