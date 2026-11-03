import {
  any,
  boolean,
  brand,
  callbackInterface,
  defineInterface,
  dictionary,
  dictionaryLike,
  domString,
  implementsInterface,
  instance,
  integer,
  isObject,
  nullable,
  optional,
  sequence,
  setEventHandlerHooks,
  unsignedLong,
  usvString,
  type Converter,
} from "../shared/webidl";
import { DOMException } from "./errors";
import { reportException } from "./format";
import { native } from "./native";

type Listener = ((event: Event) => void) | { handleEvent(event: Event): void };
type ListenerArgument =
  ((event: never) => unknown) | { handleEvent(event: never): unknown };

interface Registration {
  listener: Listener;
  capture: boolean;
  passive: boolean;
  once: boolean;
  removed: boolean;
  remove?: () => void;
}

export interface EventInit {
  bubbles?: boolean;
  cancelable?: boolean;
  composed?: boolean;
}

const flag = { convert: boolean, fallback: false };
const eventInit = dictionary<Required<EventInit>>({
  bubbles: flag,
  cancelable: flag,
  composed: flag,
});

let setTrusted: (event: Event, trusted: boolean) => void;
let setPassive: (event: Event, passive: boolean) => void;
let initialize: (
  event: Event,
  type: string,
  bubbles: boolean,
  cancelable: boolean,
) => boolean;
let beginDispatch: (event: Event, target: EventTarget) => void;
let endDispatch: (event: Event) => void;
let propagationStopped: (event: Event) => boolean;
let immediatelyStopped: (event: Event) => boolean;
let typeOf: (event: Event) => string;
let canceled: (event: Event) => boolean;
let cancel: (event: Event) => void;

export const Event = defineInterface(
  class Event {
    declare static readonly NONE: 0;
    declare static readonly CAPTURING_PHASE: 1;
    declare static readonly AT_TARGET: 2;
    declare static readonly BUBBLING_PHASE: 3;
    declare readonly NONE: 0;
    declare readonly CAPTURING_PHASE: 1;
    declare readonly AT_TARGET: 2;
    declare readonly BUBBLING_PHASE: 3;

    #type: string;
    #bubbles: boolean;
    #cancelable: boolean;
    #composed: boolean;
    #timeStamp = native.now();
    #trusted = false;
    #target: EventTarget | null = null;
    #dispatching = false;
    #canceled = false;
    #inPassiveListener = false;
    #propagationStopped = false;
    #immediateStopped = false;

    static [brand](value: object) {
      return #type in value;
    }

    static {
      setTrusted = (event, trusted) => {
        event.#trusted = trusted;
      };
      setPassive = (event, passive) => {
        event.#inPassiveListener = passive;
      };
      initialize = (event, type, bubbles, cancelable) => {
        if (event.#dispatching) {
          return false;
        }
        event.#type = type;
        event.#bubbles = bubbles;
        event.#cancelable = cancelable;
        event.#trusted = false;
        event.#target = null;
        event.#canceled = false;
        event.#propagationStopped = false;
        event.#immediateStopped = false;
        return true;
      };
      beginDispatch = (event, target) => {
        if (event.#dispatching) {
          throw new DOMException(
            "the event is already being dispatched",
            "InvalidStateError",
          );
        }
        event.#dispatching = true;
        event.#target = target;
      };
      endDispatch = (event) => {
        event.#dispatching = false;
        event.#propagationStopped = false;
        event.#immediateStopped = false;
      };
      propagationStopped = (event) => event.#propagationStopped;
      immediatelyStopped = (event) => event.#immediateStopped;
      typeOf = (event) => event.#type;
      canceled = (event) => event.#canceled;
      cancel = (event) => event.#cancel();
    }

    constructor(type: string, init?: EventInit) {
      const { bubbles, cancelable, composed } = init as Required<EventInit>;
      this.#type = type;
      this.#bubbles = bubbles;
      this.#cancelable = cancelable;
      this.#composed = composed;
    }

    get type(): string {
      return this.#type;
    }

    get bubbles(): boolean {
      return this.#bubbles;
    }

    get cancelable(): boolean {
      return this.#cancelable;
    }

    get composed(): boolean {
      return this.#composed;
    }

    get timeStamp(): number {
      return this.#timeStamp;
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
      return this.#dispatching ? 2 : 0;
    }

    get defaultPrevented(): boolean {
      return this.#canceled;
    }

    get returnValue(): boolean {
      return !this.#canceled;
    }

    set returnValue(value: boolean) {
      if (!value) {
        this.#cancel();
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

    #cancel(): void {
      if (this.#cancelable && !this.#inPassiveListener) {
        this.#canceled = true;
      }
    }

    preventDefault(): void {
      this.#cancel();
    }

    stopPropagation(): void {
      this.#propagationStopped = true;
    }

    stopImmediatePropagation(): void {
      this.#propagationStopped = true;
      this.#immediateStopped = true;
    }

    initEvent(type: string, bubbles = false, cancelable = false): void {
      initialize(this, type, bubbles, cancelable);
    }
  },
  {
    construct: [domString, optional(eventInit)],
    operations: {
      composedPath: [],
      preventDefault: [],
      stopPropagation: [],
      stopImmediatePropagation: [],
      initEvent: [
        domString,
        optional(boolean, false),
        optional(boolean, false),
      ],
    },
    setters: { returnValue: boolean, cancelBubble: boolean },
    constants: { NONE: 0, CAPTURING_PHASE: 1, AT_TARGET: 2, BUBBLING_PHASE: 3 },
    unforgeable: ["isTrusted"],
  },
);
export type Event = InstanceType<typeof Event>;

export interface CustomEventInit<T = unknown> extends EventInit {
  detail?: T;
}

export const CustomEvent = defineInterface(
  class CustomEvent<T = unknown> extends Event {
    #detail: T | null;

    static [brand](value: object) {
      return #detail in value;
    }

    constructor(type: string, init?: CustomEventInit<T>) {
      super(type, init);
      this.#detail = (init as { detail: T | null }).detail;
    }

    get detail(): T | null {
      return this.#detail;
    }

    initCustomEvent(
      type: string,
      bubbles = false,
      cancelable = false,
      detail: T | null = null,
    ): void {
      if (initialize(this, type, bubbles, cancelable)) {
        this.#detail = detail;
      }
    }
  },
  {
    construct: [
      domString,
      optional(
        dictionary({ detail: { convert: any, fallback: null } }, eventInit),
      ),
    ],
    operations: {
      initCustomEvent: [
        domString,
        optional(boolean, false),
        optional(boolean, false),
        optional(any, null),
      ],
    },
  },
);
export type CustomEvent = InstanceType<typeof CustomEvent>;

export interface ErrorEventInit extends EventInit {
  colno?: number;
  error?: unknown;
  filename?: string;
  lineno?: number;
  message?: string;
}

export const ErrorEvent = defineInterface(
  class ErrorEvent extends Event {
    #message: string;
    #filename: string;
    #lineno: number;
    #colno: number;
    #error: unknown;

    static [brand](value: object) {
      return #message in value;
    }

    constructor(type: string, init?: ErrorEventInit) {
      super(type, init);
      ({
        colno: this.#colno,
        error: this.#error,
        filename: this.#filename,
        lineno: this.#lineno,
        message: this.#message,
      } = init as Required<ErrorEventInit>);
    }

    get message(): string {
      return this.#message;
    }

    get filename(): string {
      return this.#filename;
    }

    get lineno(): number {
      return this.#lineno;
    }

    get colno(): number {
      return this.#colno;
    }

    get error(): unknown {
      return this.#error;
    }
  },
  {
    construct: [
      domString,
      optional(
        dictionary(
          {
            colno: { convert: unsignedLong, fallback: 0 },
            error: any,
            filename: { convert: usvString, fallback: "" },
            lineno: { convert: unsignedLong, fallback: 0 },
            message: { convert: domString, fallback: "" },
          },
          eventInit,
        ),
      ),
    ],
  },
);
export type ErrorEvent = InstanceType<typeof ErrorEvent>;

let abortedOf: (signal: AbortSignal) => boolean;
let addAbortAlgorithm: (
  signal: AbortSignal,
  algorithm: () => void,
) => () => void;
let retain: (signal: EventTarget) => void;
let listening: (target: EventTarget, type: string) => boolean;

interface ListenerOptions {
  capture: boolean;
  once: boolean;
  passive?: boolean;
  signal?: object;
}

const listenerOptions = dictionary<{ capture: boolean }>({ capture: flag });
const addListenerOptions = dictionary<ListenerOptions>(
  {
    once: flag,
    passive: boolean,
    signal: (value, context): unknown => instance(AbortSignal)(value, context),
  },
  listenerOptions,
);
const addOptions: Converter = dictionaryLike((value, context) =>
  value === undefined || value === null || isObject(value)
    ? addListenerOptions(value, context)
    : { capture: !!value, once: false },
);
const removeOptions: Converter = dictionaryLike((value, context) =>
  value === undefined || value === null || isObject(value)
    ? listenerOptions(value, context)
    : { capture: !!value },
);

let dispatch: (target: EventTarget, event: Event, trusted: boolean) => boolean;

export const EventTarget = defineInterface(
  class EventTarget {
    #listeners = new Map<string, Registration[]>();
    #handlers = new Map<string, { value: unknown; listener: Listener }>();

    static [brand](value: object) {
      return #listeners in value;
    }

    static {
      listening = (target, type) =>
        (target.#listeners.get(type)?.length ?? 0) > 0;
      dispatch = (target, event, trusted) => {
        beginDispatch(event, target);
        setTrusted(event, trusted);
        try {
          target.#invoke(event, true);
          target.#invoke(event, false);
        } finally {
          endDispatch(event);
        }
        return !canceled(event);
      };
      setEventHandlerHooks({
        get: (target, type) =>
          (target as EventTarget).#handlers.get(type)?.value ?? null,
        set: (object, type, value) => {
          const target = object as EventTarget;
          const slot = target.#handlers.get(type);
          if (slot !== undefined && value !== null) {
            slot.value = value;
            return;
          }
          if (slot !== undefined) {
            target.#handlers.delete(type);
            target.#remove(
              type,
              (registration) => registration.listener === slot.listener,
            );
            return;
          }
          if (value !== null) {
            const created: { value: unknown; listener: Listener } = {
              value,
              listener(this: EventTarget, event: Event) {
                if (
                  typeof created.value === "function" &&
                  Reflect.apply(created.value, this, [event]) === false
                ) {
                  cancel(event);
                }
              },
            };
            target.#handlers.set(type, created);
            target.#add(type, {
              listener: created.listener,
              capture: false,
              passive: false,
              once: false,
              removed: false,
            });
          }
        },
      });
    }

    #add(type: string, registration: Registration): void {
      const registrations = this.#listeners.get(type) ?? [];
      registrations.push(registration);
      this.#listeners.set(type, registrations);
      if (type === "abort") {
        retain(this);
      }
    }

    #remove(
      type: string,
      match: (registration: Registration) => boolean,
    ): void {
      const registrations = this.#listeners.get(type);
      const index = registrations?.findIndex(match) ?? -1;
      if (registrations && index >= 0) {
        const [registration] = registrations.splice(index, 1);
        registration.removed = true;
        registration.remove?.();
        if (type === "abort") {
          retain(this);
        }
      }
    }

    #invoke(event: Event, capture: boolean): void {
      if (propagationStopped(event)) {
        return;
      }
      const type = typeOf(event);
      for (const registration of [...(this.#listeners.get(type) ?? [])]) {
        if (registration.removed || registration.capture !== capture) {
          continue;
        }
        if (registration.once) {
          this.#remove(type, (item) => item === registration);
        }
        setPassive(event, registration.passive);
        try {
          const { listener } = registration;
          if (typeof listener === "function") {
            Reflect.apply(listener, this, [event]);
          } else {
            const handleEvent: unknown = listener.handleEvent;
            if (typeof handleEvent !== "function") {
              throw new TypeError(
                "the event listener has no handleEvent method",
              );
            }
            Reflect.apply(handleEvent, listener, [event]);
          }
        } catch (error) {
          reportException(error);
        }
        setPassive(event, false);
        if (immediatelyStopped(event)) {
          break;
        }
      }
    }

    addEventListener(
      type: string,
      callback: ListenerArgument | null,
      options?: boolean | Web.AddEventListenerOptions,
    ): void {
      const { capture, once, passive = false } = options as ListenerOptions;
      const signal = (options as ListenerOptions).signal as
        AbortSignal | undefined;
      const listener = callback as Listener | null;
      if ((signal !== undefined && abortedOf(signal)) || listener === null) {
        return;
      }
      if (
        this.#listeners
          .get(type)
          ?.some(
            (item) => item.listener === listener && item.capture === capture,
          )
      ) {
        return;
      }
      const registration: Registration = {
        listener,
        capture,
        passive,
        once,
        removed: false,
      };
      if (signal !== undefined) {
        registration.remove = addAbortAlgorithm(signal, () =>
          this.#remove(type, (item) => item === registration),
        );
      }
      this.#add(type, registration);
    }

    removeEventListener(
      type: string,
      callback: ListenerArgument | null,
      options?: boolean | Web.EventListenerOptions,
    ): void {
      const { capture } = options as { capture: boolean };
      if (callback !== null) {
        this.#remove(
          type,
          (item) => item.listener === callback && item.capture === capture,
        );
      }
    }

    dispatchEvent(event: Event): boolean {
      return dispatch(this, event, false);
    }
  },
  {
    construct: [],
    operations: {
      addEventListener: [
        domString,
        nullable(callbackInterface),
        optional(addOptions),
      ],
      removeEventListener: [
        domString,
        nullable(callbackInterface),
        optional(removeOptions),
      ],
      dispatchEvent: [instance(Event)],
    },
  },
);
export type EventTarget = InstanceType<typeof EventTarget>;

const fire = (target: EventTarget, event: Event): boolean =>
  dispatch(target, event, true);

const constructing = Symbol("AbortSignal");
let signalAbort: (signal: AbortSignal, reason: unknown) => void;
let createDependent: (signals: readonly AbortSignal[]) => AbortSignal;
let createSignal: () => AbortSignal;
const timeoutMilliseconds = integer("unsigned long long", "EnforceRange");
const longestTimer = 2 ** 31 - 1;

const after = (milliseconds: number, steps: () => void) => {
  setTimeout(
    milliseconds > longestTimer
      ? () => after(milliseconds - longestTimer, steps)
      : steps,
    Math.min(milliseconds, longestTimer),
  );
};

export const AbortSignal = defineInterface(
  class AbortSignal extends EventTarget {
    #aborted = false;
    #reason: unknown = undefined;
    #algorithms = new Set<() => void>();
    #dependent = false;
    #sources: WeakRef<AbortSignal>[] = [];
    #dependents = new Set<WeakRef<AbortSignal>>();
    #pruned = 0;
    #retained = new Set<AbortSignal>();
    #self = new WeakRef(this);
    declare onabort: ((event: globalThis.Event) => unknown) | null;

    static [brand](value: object) {
      return #aborted in value;
    }

    static {
      createSignal = () => new AbortSignal(constructing);
      abortedOf = (signal) => signal.#aborted;
      addAbortAlgorithm = (signal, algorithm) => {
        if (signal.#aborted) {
          return () => {};
        }
        signal.#algorithms.add(algorithm);
        retain(signal);
        return () => {
          if (signal.#algorithms.delete(algorithm)) {
            retain(signal);
          }
        };
      };
      retain = (target) => {
        const signal = target as AbortSignal;
        if (!(#aborted in signal) || !signal.#dependent) {
          return;
        }
        const interested =
          !signal.#aborted &&
          (signal.#algorithms.size > 0 || listening(signal, "abort"));
        for (const reference of signal.#sources) {
          const source = reference.deref();
          if (source !== undefined && interested) {
            source.#retained.add(signal);
          } else if (source !== undefined) {
            source.#retained.delete(signal);
          }
        }
      };
      signalAbort = (signal, reason) => {
        if (signal.#aborted) {
          return;
        }
        signal.#settle(
          reason === undefined
            ? new DOMException("the operation was aborted", "AbortError")
            : reason,
        );
        const dependents: AbortSignal[] = [];
        for (const reference of signal.#dependents) {
          const dependent = reference.deref();
          if (dependent !== undefined && !dependent.#aborted) {
            dependent.#settle(signal.#reason);
            dependents.push(dependent);
          }
        }
        signal.#steps();
        for (const dependent of dependents) {
          dependent.#steps();
        }
      };
      createDependent = (signals) => {
        const result = new AbortSignal(constructing);
        const aborted = signals.find((signal) => signal.#aborted);
        if (aborted !== undefined) {
          result.#aborted = true;
          result.#reason = aborted.#reason;
          return result;
        }
        result.#dependent = true;
        const sources = new Set<AbortSignal>();
        for (const signal of signals) {
          if (!signal.#dependent) {
            sources.add(signal);
            continue;
          }
          for (const reference of signal.#sources) {
            const source = reference.deref();
            if (source !== undefined) {
              sources.add(source);
            }
          }
        }
        for (const source of sources) {
          result.#sources.push(source.#self);
          source.#dependents.add(result.#self);
          if (source.#dependents.size > 2 * source.#pruned + 16) {
            for (const reference of source.#dependents) {
              if (reference.deref() === undefined) {
                source.#dependents.delete(reference);
              }
            }
            source.#pruned = source.#dependents.size;
          }
        }
        return result;
      };
    }

    constructor(key?: unknown) {
      if (key !== constructing) {
        throw new TypeError("Illegal constructor");
      }
      super();
    }

    #settle(reason: unknown): void {
      this.#aborted = true;
      this.#reason = reason;
      for (const reference of this.#sources) {
        const source = reference.deref();
        if (source !== undefined) {
          source.#retained.delete(this);
          source.#dependents.delete(this.#self);
        }
      }
      this.#sources = [];
    }

    #steps(): void {
      const algorithms = [...this.#algorithms];
      this.#algorithms.clear();
      for (const algorithm of algorithms) {
        algorithm();
      }
      fire(this, new Event("abort"));
      this.#dependents.clear();
      this.#retained.clear();
    }

    static abort(reason?: unknown): AbortSignal {
      const signal = new AbortSignal(constructing);
      signal.#aborted = true;
      signal.#reason =
        reason === undefined
          ? new DOMException("the operation was aborted", "AbortError")
          : reason;
      return signal;
    }

    static timeout(milliseconds: number): AbortSignal {
      const signal = new AbortSignal(constructing);
      after(milliseconds, () =>
        signalAbort(
          signal,
          new DOMException("the operation timed out", "TimeoutError"),
        ),
      );
      return signal;
    }

    static any(signals: Iterable<globalThis.AbortSignal>): AbortSignal {
      return createDependent(signals as AbortSignal[]);
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
  },
  {
    operations: { throwIfAborted: [] },
    statics: {
      abort: [optional(any)],
      timeout: [timeoutMilliseconds],
      any: [
        sequence((value, context): unknown =>
          instance(AbortSignal)(value, context),
        ),
      ],
    },
    events: ["abort"],
  },
);
export type AbortSignal = InstanceType<typeof AbortSignal>;

export const isAbortSignal = (value: unknown): value is AbortSignal =>
  implementsInterface(AbortSignal, value);

export const onAbort = (
  signal: globalThis.AbortSignal,
  algorithm: () => void,
): (() => void) => {
  if (isAbortSignal(signal)) {
    return addAbortAlgorithm(signal, algorithm);
  }
  signal.addEventListener("abort", algorithm, { once: true });
  return () => signal.removeEventListener("abort", algorithm);
};

export const AbortController = defineInterface(
  class AbortController {
    readonly #signal = createSignal();

    static [brand](value: object) {
      return #signal in value;
    }

    get signal(): AbortSignal {
      return this.#signal;
    }

    abort(reason?: unknown): void {
      signalAbort(this.#signal, reason);
    }
  },
  {
    construct: [],
    operations: { abort: [optional(any)] },
  },
);
export type AbortController = InstanceType<typeof AbortController>;
