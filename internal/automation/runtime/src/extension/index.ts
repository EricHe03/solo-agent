import structuredClone from "@ungap/structured-clone";
import { URL, URLSearchParams } from "whatwg-url-minimum";

import { deliver, end, settle, sleep } from "./async";
import { crypto } from "./crypto";
import { atob, btoa, TextDecoder, TextEncoder } from "./encoding";
import { DOMException } from "./errors";
import { AbortController, AbortSignal, CustomEvent, Event, EventTarget } from "./events";
import { hooks } from "./extension";
import { Blob, fetch, Headers, Request, Response } from "./fetch";
import { describe, formatAll } from "./format";
import { bind, native, type Native } from "./native";
import { launch, replGlobals } from "./repl";

const define = (values: Record<string, unknown>) => {
  for (const [name, value] of Object.entries(values)) {
    Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: false });
  }
};

const print = (level: string) => (...values: unknown[]) => native.print(level, formatAll(...values));

export function install(binding: Native) {
  bind(binding);
  define({
    AbortController, AbortSignal, Event, EventTarget, CustomEvent, DOMException, TextEncoder, TextDecoder, atob, btoa,
    structuredClone: (value: unknown) => structuredClone(value), URL, URLSearchParams, crypto, fetch, Headers, Request,
    Response, Blob, sleep,
    queueMicrotask: (callback: () => void) => {
      if (typeof callback !== "function") {
        throw new TypeError("the callback is not a function");
      }
      void Promise.resolve().then(callback);
    },
    console: Object.freeze({ log: print("info"), info: print("info"), warn: print("warn"), error: print("error"), debug: print("debug") }),
    navigator: Object.freeze({ userAgent: "Swipt", language: native.languages.split("\n")[0] || "en", languages: Object.freeze(native.languages.split("\n").filter(Boolean)) }),
  });
  return { settle, deliver, end, describe, ...hooks, launch, repl: () => define(replGlobals()) };
}
