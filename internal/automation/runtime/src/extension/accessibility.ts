import { invoke } from "./async";
import { AccessibilityElement, encode, isSelector, refOf, scripted, snapshotOf, type RawSnapshot, type Selector } from "./elements";
import { inspect } from "./format";
import { act, check, optionsOf, signalOf, type Options } from "./options";

const defaultTimeout = 10_000;

const view = (options: unknown) => {
  const { scope = "frontApp", full = false } = optionsOf(options, ["scope", "full"]);
  if (scope !== "frontApp" && scope !== "screen") {
    throw new TypeError("scope must be frontApp or screen");
  }
  if (typeof full !== "boolean") {
    throw new TypeError("full must be a boolean");
  }
  return { scope, full };
};

const query = (selector: unknown): unknown => {
  if (typeof selector === "function" || !isSelector(selector)) {
    throw new TypeError("a locator takes query objects; match with a function on accessibility.snapshot()");
  }
  const encoded = encode(selector);
  if (encoded.references > 0) {
    throw new TypeError("a locator's query cannot hold an element of a snapshot");
  }
  if (scripted(encoded)) {
    throw new TypeError(`the device cannot run a RegExp in ${inspect(selector)}; match it on accessibility.snapshot()`);
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

export class AccessibilityLocator {
  readonly #selectors: unknown[];
  readonly #shown: string;

  constructor(selectors: unknown[], shown: string) {
    this.#selectors = selectors;
    this.#shown = shown;
    Object.freeze(this);
  }

  tap(options?: Options): Promise<void> {
    const { timeoutMs, ...rest } = optionsOf(options, ["count", "holdMs", "timeoutMs"]);
    return act("accessibility.locate", [this.#selectors, { action: "tap", ...rest }, timeoutOf(timeoutMs)], options);
  }

  tapEach(options?: Options): Promise<void> {
    return act("accessibility.locate", [this.#selectors, { action: "tap", each: true, ...optionsOf(options, ["count", "holdMs"]) }], options);
  }

  setText(text: string, options?: Options): Promise<void> {
    if (typeof text !== "string") {
      throw new TypeError("the text must be a string");
    }
    const { timeoutMs } = optionsOf(options, ["timeoutMs"]);
    return act("accessibility.locate", [this.#selectors, { action: "setText", text }, timeoutOf(timeoutMs)], options);
  }

  perform(action: string, options?: Options): Promise<void> {
    if (typeof action !== "string") {
      throw new TypeError("the action must be a string");
    }
    const { timeoutMs } = optionsOf(options, ["timeoutMs"]);
    return act("accessibility.locate", [this.#selectors, { action: "perform", name: action }, timeoutOf(timeoutMs)], options);
  }

  toString(): string {
    return `AccessibilityLocator ${this.#shown}`;
  }
}

export const locator = (selector: unknown) => {
  const selectors = Array.isArray(selector) ? selector : [selector];
  if (selectors.length === 0) {
    throw new TypeError("a locator needs a query");
  }
  return new AccessibilityLocator(selectors.map(query), selectors.map(item => inspect(item)).join(" or "));
};

export const snapshot = async (options?: Options) =>
  snapshotOf(await invoke<RawSnapshot>("accessibility.snapshot", [view(options)], { signal: signalOf(options) }));

export const find = async (selector: Selector, options?: Options): Promise<AccessibilityElement | null> => {
  if (!isSelector(selector)) {
    throw new TypeError("expected a selector: an object of element fields, or a function of an element");
  }
  const found = snapshotOf(await invoke<RawSnapshot>("accessibility.find", [encode(selector).value], { signal: signalOf(check(options, [])) }));
  return found.find(selector);
};

export const tap = async (element: AccessibilityElement, options?: Options) => {
  if (!(element instanceof AccessibilityElement)) {
    throw new TypeError("accessibility.tap takes an element of a snapshot; tap a query with accessibility.locator, or a point with input.tap");
  }
  return act("accessibility.tap", [refOf(element), optionsOf(options, ["count", "holdMs"])], options);
};
