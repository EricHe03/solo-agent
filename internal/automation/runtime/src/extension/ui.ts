import { invoke } from "./async";
import { act, check, optionsOf, signalOf } from "./device";
import { Element, encode, isSelector, refOf, scripted, snapshotOf, type RawSnapshot, type Selector, type Snapshot } from "./elements";
import { inspect } from "./format";

type Options = { signal?: AbortSignal };

const defaultTimeout = 10_000;

const view = (options: unknown) => {
  const { scope = "screen", full = false } = optionsOf(options, ["scope", "full"]);
  if (scope !== "screen" && scope !== "frontApp") {
    throw new TypeError("scope must be screen or frontApp");
  }
  if (typeof full !== "boolean") {
    throw new TypeError("full must be a boolean");
  }
  return { scope, full };
};

const query = (selector: unknown): unknown => {
  if (typeof selector === "function" || !isSelector(selector)) {
    throw new TypeError("a locator takes selector objects; match with a function on ui.snapshot()");
  }
  const encoded = encode(selector);
  if (encoded.references > 0) {
    throw new TypeError("a locator's selector cannot hold an element of a snapshot");
  }
  if (scripted(encoded)) {
    throw new TypeError(`the device cannot run a RegExp in ${inspect(selector)}; match it on ui.snapshot()`);
  }
  return encoded.value;
};

const timeoutOf = (timeoutMs: unknown): number | null => {
  if (timeoutMs === undefined) {
    return defaultTimeout;
  }
  if (timeoutMs === Infinity) {
    return null;
  }
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs < 0) {
    throw new TypeError("timeoutMs must be a non-negative number of milliseconds, or Infinity");
  }
  return timeoutMs;
};

class Locator {
  readonly #selectors: unknown[];
  readonly #shown: string;

  constructor(selectors: unknown[], shown: string) {
    this.#selectors = selectors;
    this.#shown = shown;
    Object.freeze(this);
  }

  tap(options?: Options): Promise<void> {
    const { timeoutMs, ...rest } = optionsOf(options, ["count", "holdMs", "timeoutMs"]);
    return act("ui.locate", [this.#selectors, { action: "tap", ...rest }, timeoutOf(timeoutMs)], options);
  }

  tapEach(options?: Options): Promise<void> {
    return act("ui.locate", [this.#selectors, { action: "tap", each: true, ...optionsOf(options, ["count", "holdMs"]) }], options);
  }

  setText(text: string, options?: Options): Promise<void> {
    if (typeof text !== "string") {
      throw new TypeError("the text must be a string");
    }
    const { timeoutMs } = optionsOf(options, ["timeoutMs"]);
    return act("ui.locate", [this.#selectors, { action: "setText", text }, timeoutOf(timeoutMs)], options);
  }

  perform(action: string, options?: Options): Promise<void> {
    if (typeof action !== "string") {
      throw new TypeError("the action must be a string");
    }
    const { timeoutMs } = optionsOf(options, ["timeoutMs"]);
    return act("ui.locate", [this.#selectors, { action: "perform", name: action }, timeoutOf(timeoutMs)], options);
  }

  toString(): string {
    return `Locator ${this.#shown}`;
  }
}

export const ui = Object.freeze({
  locator: (selector: unknown) => {
    const selectors = Array.isArray(selector) ? selector : [selector];
    if (selectors.length === 0) {
      throw new TypeError("a locator needs a selector");
    }
    return new Locator(selectors.map(query), selectors.map(item => inspect(item)).join(" or "));
  },
  snapshot: async (options?: Options) =>
    snapshotOf(await invoke<RawSnapshot>("ui.snapshot", [view(options)], { signal: signalOf(options) })),
  find: async (selector: Selector, options?: Options): Promise<Element | null> => {
    if (!isSelector(selector)) {
      throw new TypeError("expected a selector: an object of element fields, or a function of an element");
    }
    const snapshot: Snapshot = snapshotOf(await invoke<RawSnapshot>("ui.find", [encode(selector).value], { signal: signalOf(check(options, [])) }));
    return snapshot.find(selector);
  },
  tap: async (element: Element, options?: Options) => {
    if (!(element instanceof Element)) {
      throw new TypeError("ui.tap takes an element of a snapshot; tap a selector with ui.locator, or a point with device.tap");
    }
    return act("ui.tap", [refOf(element), optionsOf(options, ["count", "holdMs"])], options);
  },
});
