import { invoke } from "./async";
import { AccessibilityElement, encode, isSelector, refOf, snapshotOf, type RawSnapshot, type Selector } from "./elements";
import { act, check, optionsOf, signalOf, type Options } from "./options";

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

const selectorsOf = (selector: unknown): Selector[] => {
  const selectors = Array.isArray(selector) ? selector : [selector];
  if (selectors.length === 0) {
    throw new TypeError("find needs a selector");
  }
  for (const item of selectors) {
    if (!isSelector(item)) {
      throw new TypeError("expected a selector: an object of element fields, or a function of an element");
    }
  }
  return selectors as Selector[];
};

const limitOf = (value: unknown, name: string): number => {
  if (value === undefined) {
    return 0;
  }
  if (value === Infinity) {
    return Infinity;
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) {
    throw new TypeError(`${name} must be a non-negative number of milliseconds, or Infinity`);
  }
  return value;
};

const elementOf = (element: unknown, operation: string): string => {
  if (!(element instanceof AccessibilityElement)) {
    throw new TypeError(`${operation} takes an element of a snapshot`);
  }
  return refOf(element);
};

interface Found {
  snapshot: RawSnapshot | null;
  seen: number;
}

export const snapshot = async (options?: Options) =>
  snapshotOf(await invoke<RawSnapshot>("accessibility.snapshot", [view(options)], { signal: signalOf(options) }));

export const find = async (selector: unknown, options?: Options): Promise<AccessibilityElement | null> => {
  const selectors = selectorsOf(selector);
  const { timeoutMs, poll = false, pollTimeoutMs } = optionsOf(options, ["timeoutMs", "poll", "pollTimeoutMs"]);
  const timeout = limitOf(timeoutMs, "timeoutMs");
  if (typeof poll !== "boolean") {
    throw new TypeError("poll must be a boolean");
  }
  if (pollTimeoutMs !== undefined && !poll) {
    throw new TypeError("pollTimeoutMs applies with poll");
  }
  const pollLimit = pollTimeoutMs === undefined ? Infinity : limitOf(pollTimeoutMs, "pollTimeoutMs");
  const signal = signalOf(options);
  const encoded = selectors.map(item => encode(item).value);
  const started = Date.now();
  const deadline = started + timeout;
  const pollUntil = poll ? started + pollLimit : -Infinity;
  for (;;) {
    const found = await invoke<Found>("accessibility.find", [encoded], { signal });
    if (found.snapshot !== null) {
      const taken = snapshotOf(found.snapshot);
      for (const item of selectors) {
        const element = taken.findAll(item)[0];
        if (element !== undefined) {
          return element;
        }
      }
    }
    const now = Date.now();
    if (now >= deadline) {
      return null;
    }
    if (now < pollUntil) {
      continue;
    }
    await invoke("accessibility.changed", [found.seen, deadline === Infinity ? null : deadline - now], { signal });
  }
};

export const setText = (element: unknown, text: unknown, options?: Options) => {
  const ref = elementOf(element, "accessibility.setText");
  if (typeof text !== "string") {
    throw new TypeError("the text must be a string");
  }
  return act("accessibility.setText", [ref, text], check(options, []));
};

export const perform = (element: unknown, action: unknown, options?: Options) => {
  const ref = elementOf(element, "accessibility.perform");
  if (typeof action !== "string") {
    throw new TypeError("the action must be a string");
  }
  return act("accessibility.perform", [ref, action], check(options, []));
};
