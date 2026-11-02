import { URL, URLSearchParams } from "whatwg-url-minimum";

import { invoke } from "./async";
import { Blob, blobBytes, objectURL } from "./blob";
import { atob, bytesOf, TextDecoder, TextEncoder } from "./encoding";
import { failureOf } from "./errors";
import { AbortController, type AbortSignal } from "./events";
import { encodeMultipart, FormData, parseForm } from "./form";
import { native } from "./native";
import { bytesStream, errorNative, isDisturbed, nativeReadable, nativeWritable, readAll, ReadableStream, takeNative } from "./streams";

type HeadersInit = Headers | Record<string, string> | Iterable<readonly [string, string]>;
type Guard = "none" | "immutable";

const token = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;
const invalidValue = /[\0\r\n]|[^\0-\xff]/;
const whitespace = /^[\t\n\r ]+|[\t\n\r ]+$/g;

let guard: (headers: Headers, value: Guard) => Headers;
let headerList: (headers: Headers) => [string, string][];

export class Headers {
  #entries: [string, string][] = [];
  #guard: Guard = "none";

  static {
    guard = (headers, value) => {
      headers.#guard = value;
      return headers;
    };
    headerList = headers => headers.#entries.map(([name, value]) => [name, value]);
  }

  constructor(init?: HeadersInit) {
    if (init instanceof Headers) {
      this.#entries = init.#entries.map(([name, value]) => [name, value]);
    } else if (init !== undefined && init !== null) {
      if (typeof init !== "object") {
        throw new TypeError("the headers are not an object or a sequence of pairs");
      }
      const pairs = Symbol.iterator in init ? Array.from(init as Iterable<readonly [string, string]>, pair => [...pair]) : Object.entries(init);
      for (const pair of pairs) {
        if (pair.length !== 2) {
          throw new TypeError("a header needs a name and a value");
        }
        this.append(pair[0], pair[1]);
      }
    }
  }

  #name(name: string): string {
    const text = String(name);
    if (!token.test(text)) {
      throw new TypeError(`${JSON.stringify(text)} is not a valid header name`);
    }
    return text.toLowerCase();
  }

  #value(value: string): string {
    const text = String(value).replace(whitespace, "");
    if (invalidValue.test(text)) {
      throw new TypeError(`${JSON.stringify(text)} is not a valid header value`);
    }
    return text;
  }

  #mutable(): void {
    if (this.#guard === "immutable") {
      throw new TypeError("the headers are immutable");
    }
  }

  append(name: string, value: string): void {
    const entry: [string, string] = [this.#name(name), this.#value(value)];
    this.#mutable();
    this.#entries.push(entry);
  }

  set(name: string, value: string): void {
    const key = this.#name(name);
    const text = this.#value(value);
    this.#mutable();
    const index = this.#entries.findIndex(([item]) => item === key);
    if (index < 0) {
      this.#entries.push([key, text]);
      return;
    }
    this.#entries[index] = [key, text];
    this.#entries = this.#entries.filter(([item], position) => position <= index || item !== key);
  }

  delete(name: string): void {
    const key = this.#name(name);
    this.#mutable();
    this.#entries = this.#entries.filter(([item]) => item !== key);
  }

  get(name: string): string | null {
    const key = this.#name(name);
    const values = this.#entries.filter(([item]) => item === key).map(([, value]) => value);
    return values.length === 0 ? null : values.join(", ");
  }

  getSetCookie(): string[] {
    return this.#entries.filter(([name]) => name === "set-cookie").map(([, value]) => value);
  }

  has(name: string): boolean {
    const key = this.#name(name);
    return this.#entries.some(([item]) => item === key);
  }

  forEach(callback: (value: string, name: string, headers: Headers) => void, thisArg?: unknown): void {
    for (const [name, value] of this) {
      callback.call(thisArg, value, name, this);
    }
  }

  *entries(): IterableIterator<[string, string]> {
    const names = [...new Set(this.#entries.map(([name]) => name))].sort();
    for (const name of names) {
      if (name === "set-cookie") {
        for (const value of this.getSetCookie()) {
          yield [name, value];
        }
      } else {
        yield [name, this.get(name)!];
      }
    }
  }

  *keys(): IterableIterator<string> {
    for (const [name] of this.entries()) {
      yield name;
    }
  }

  *values(): IterableIterator<string> {
    for (const [, value] of this.entries()) {
      yield value;
    }
  }

  [Symbol.iterator](): IterableIterator<[string, string]> {
    return this.entries();
  }

  get [Symbol.toStringTag](): string {
    return "Headers";
  }
}

type BodyInit = string | ArrayBuffer | ArrayBufferView | Blob | URLSearchParams | FormData | ReadableStream<Uint8Array> | null | undefined;
type Source = { bytes: Uint8Array } | { stream: ReadableStream<Uint8Array> };

const extract = (body: BodyInit): { source: Source; type: string | null } => {
  if (body instanceof ReadableStream) {
    if (isDisturbed(body)) {
      throw new TypeError("the body stream is locked or was read");
    }
    return { source: { stream: body }, type: null };
  }
  if (body instanceof Blob) {
    return { source: { bytes: blobBytes(body).slice() }, type: body.type || null };
  }
  if (body instanceof FormData) {
    const { bytes, type } = encodeMultipart(body);
    return { source: { bytes }, type };
  }
  if (body instanceof URLSearchParams) {
    return { source: { bytes: new TextEncoder().encode(body.toString()) }, type: "application/x-www-form-urlencoded;charset=UTF-8" };
  }
  if (ArrayBuffer.isView(body) || body instanceof ArrayBuffer) {
    return { source: { bytes: bytesOf(body).slice() }, type: null };
  }
  return { source: { bytes: new TextEncoder().encode(String(body)) }, type: "text/plain;charset=UTF-8" };
};

const internal = Symbol("internal");

interface BodyState {
  source: Source | null;
  used: boolean;
  signal?: AbortSignal;
}

let stateOf: (body: Body) => BodyState;

const used = (state: BodyState) => state.used || (state.source !== null && "stream" in state.source && isDisturbed(state.source.stream));

const takeBody = (state: BodyState): Source | null => {
  if (used(state)) {
    throw new TypeError("the body was already read");
  }
  state.used = true;
  return state.source;
};

const teeBody = (state: BodyState): Source | null => {
  if (used(state)) {
    throw new TypeError("the body was already read");
  }
  const { source } = state;
  if (source === null) {
    return null;
  }
  if ("bytes" in source) {
    return { bytes: source.bytes.slice() };
  }
  const [first, second] = source.stream.tee();
  state.source = { stream: first };
  return { stream: second };
};

abstract class Body {
  readonly #state: BodyState;

  static {
    stateOf = body => body.#state;
  }

  protected constructor(state: BodyState) {
    this.#state = state;
  }

  abstract readonly headers: Headers;

  get body(): ReadableStream<Uint8Array> | null {
    const { source } = this.#state;
    if (source === null) {
      return null;
    }
    if ("bytes" in source) {
      this.#state.source = { stream: bytesStream(source.bytes) };
    }
    return (this.#state.source as { stream: ReadableStream<Uint8Array> }).stream;
  }

  get bodyUsed(): boolean {
    return used(this.#state);
  }

  async #consume(): Promise<Uint8Array> {
    const source = takeBody(this.#state);
    if (source === null) {
      return new Uint8Array(0);
    }
    if ("bytes" in source) {
      return source.bytes;
    }
    const id = takeNative(source.stream);
    if (id !== null) {
      const bytes = await invoke<Uint8Array | null>("stream.readAll", [id], { signal: this.#state.signal });
      return bytes instanceof Uint8Array ? bytes : new Uint8Array(0);
    }
    return readAll(source.stream);
  }

  async bytes(): Promise<Uint8Array> {
    return this.#consume();
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    const bytes = await this.#consume();
    return bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ? bytes.buffer as ArrayBuffer : bytes.slice().buffer as ArrayBuffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(await this.#consume());
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text());
  }

  async blob(): Promise<Blob> {
    return new Blob([await this.#consume()], { type: this.headers.get("content-type") ?? "" });
  }

  async formData(): Promise<FormData> {
    return parseForm(await this.#consume(), this.headers.get("content-type"));
  }
}

const standardMethods = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH"];
const forbiddenMethods = ["CONNECT", "TRACE", "TRACK"];
const redirects = ["follow", "manual", "error"] as const;

type RequestRedirect = typeof redirects[number];

export interface RequestInit {
  method?: string;
  headers?: HeadersInit;
  body?: BodyInit;
  signal?: AbortSignal | null;
  redirect?: RequestRedirect;
  duplex?: "half";
  cache?: string;
  credentials?: string;
  integrity?: string;
  keepalive?: boolean;
  mode?: string;
  priority?: string;
  referrer?: string;
  referrerPolicy?: string;
  window?: null;
}

const parseURL = (input: string): URL => {
  const url = new URL(input);
  if (url.username !== "" || url.password !== "") {
    throw new TypeError(`the URL ${JSON.stringify(input)} includes credentials; send them in an Authorization header`);
  }
  return url;
};

export class Request extends Body {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly signal: AbortSignal;
  readonly redirect: RequestRedirect;
  readonly duplex = "half";
  readonly cache: string;
  readonly credentials: string;
  readonly destination = "";
  readonly integrity: string;
  readonly keepalive: boolean;
  readonly mode: string;
  readonly referrer: string;
  readonly referrerPolicy: string;

  constructor(input: string | URL | Request, init: RequestInit = {}) {
    const base = input instanceof Request ? input : undefined;
    const url = base ? base.url : parseURL(String(input)).href;
    const method = init.method === undefined ? base?.method ?? "GET" : String(init.method);
    if (!token.test(method)) {
      throw new TypeError(`${JSON.stringify(method)} is not a valid method`);
    }
    const upper = method.toUpperCase();
    if (forbiddenMethods.includes(upper)) {
      throw new TypeError(`the method ${upper} is forbidden`);
    }
    const normalized = standardMethods.includes(upper) ? upper : method;
    const redirect = init.redirect ?? base?.redirect ?? "follow";
    if (!redirects.includes(redirect)) {
      throw new TypeError(`the redirect ${JSON.stringify(redirect)} is not one of ${redirects.join(", ")}`);
    }
    if (init.duplex !== undefined && init.duplex !== "half") {
      throw new TypeError(`the duplex ${JSON.stringify(init.duplex)} is not "half"`);
    }
    if (init.mode === "navigate") {
      throw new TypeError("a Request can't be made with the mode navigate");
    }
    const headers = new Headers(init.headers ?? base?.headers);
    let source: Source | null = null;
    if (init.body !== undefined && init.body !== null) {
      if (normalized === "GET" || normalized === "HEAD") {
        throw new TypeError(`a ${normalized} request can't have a body`);
      }
      const extracted = extract(init.body);
      if ("stream" in extracted.source && init.duplex !== "half") {
        throw new TypeError("a request with a ReadableStream body needs duplex: \"half\"");
      }
      if (extracted.type !== null && !headers.has("content-type")) {
        headers.set("content-type", extracted.type);
      }
      source = extracted.source;
    } else if (base && stateOf(base).source !== null) {
      if (normalized === "GET" || normalized === "HEAD") {
        throw new TypeError(`a ${normalized} request can't have a body`);
      }
      source = takeBody(stateOf(base));
    }
    const controller = new AbortController();
    const signal = init.signal === undefined ? base?.signal : init.signal ?? undefined;
    if (signal) {
      if (signal.aborted) {
        controller.abort(signal.reason);
      } else {
        signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true });
      }
    }
    super({ source, used: false });
    this.url = url;
    this.method = normalized;
    this.headers = headers;
    this.signal = controller.signal;
    this.redirect = redirect;
    this.cache = String(init.cache ?? base?.cache ?? "default");
    this.credentials = String(init.credentials ?? base?.credentials ?? "same-origin");
    this.integrity = String(init.integrity ?? base?.integrity ?? "");
    this.keepalive = Boolean(init.keepalive ?? base?.keepalive ?? false);
    this.mode = String(init.mode ?? base?.mode ?? "cors");
    this.referrer = String(init.referrer ?? base?.referrer ?? "about:client");
    this.referrerPolicy = String(init.referrerPolicy ?? base?.referrerPolicy ?? "");
  }

  clone(): Request {
    const source = teeBody(stateOf(this));
    const clone = new Request(this.url, {
      method: this.method, headers: this.headers, signal: this.signal, redirect: this.redirect, cache: this.cache, credentials: this.credentials,
      integrity: this.integrity, keepalive: this.keepalive, mode: this.mode, referrer: this.referrer, referrerPolicy: this.referrerPolicy,
    });
    stateOf(clone).source = source;
    return clone;
  }

  get [Symbol.toStringTag](): string {
    return "Request";
  }
}

export interface ResponseInit {
  status?: number;
  statusText?: string;
  headers?: HeadersInit;
}

interface ResponseFields {
  type: "basic" | "default" | "error";
  url: string;
  redirected: boolean;
  status: number;
  statusText: string;
  headers: Headers;
  source: Source | null;
  signal?: AbortSignal;
}

const nullBodyStatuses = [101, 103, 204, 205, 304];
const reasonPhrase = /^[\t !-~\x80-\xff]*$/;

export class Response extends Body {
  readonly type: "basic" | "default" | "error";
  readonly url: string;
  readonly redirected: boolean;
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;

  constructor(body: BodyInit = null, init: ResponseInit = {}) {
    const fields = (init as { [internal]?: ResponseFields })[internal];
    if (fields) {
      super({ source: fields.source, used: false, signal: fields.signal });
      ({ type: this.type, url: this.url, redirected: this.redirected, status: this.status, statusText: this.statusText, headers: this.headers } = fields);
      return;
    }
    const status = init.status === undefined ? 200 : Number(init.status);
    if (!Number.isInteger(status) || status < 200 || status > 599) {
      throw new RangeError(`the status ${status} is outside 200 to 599`);
    }
    const statusText = String(init.statusText ?? "");
    if (!reasonPhrase.test(statusText)) {
      throw new TypeError(`${JSON.stringify(statusText)} is not a valid status text`);
    }
    const headers = new Headers(init.headers);
    let source: Source | null = null;
    if (body !== null && body !== undefined) {
      if (nullBodyStatuses.includes(status)) {
        throw new TypeError(`a response with the status ${status} can't have a body`);
      }
      const extracted = extract(body);
      if (extracted.type !== null && !headers.has("content-type")) {
        headers.set("content-type", extracted.type);
      }
      source = extracted.source;
    }
    super({ source, used: false });
    this.type = "default";
    this.url = "";
    this.redirected = false;
    this.status = status;
    this.statusText = statusText;
    this.headers = headers;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  clone(): Response {
    const source = teeBody(stateOf(this));
    const headers = new Headers(this.headers);
    return new Response(null, {
      [internal]: { type: this.type, url: this.url, redirected: this.redirected, status: this.status, statusText: this.statusText, headers: guard(headers, this.type === "default" ? "none" : "immutable"), source, signal: stateOf(this).signal },
    } as ResponseInit);
  }

  static error(): Response {
    return new Response(null, { [internal]: { type: "error", url: "", redirected: false, status: 0, statusText: "", headers: guard(new Headers(), "immutable"), source: null } } as ResponseInit);
  }

  static json(data: unknown, init: ResponseInit = {}): Response {
    const text = JSON.stringify(data);
    if (text === undefined) {
      throw new TypeError("the data can't be serialized to JSON");
    }
    const headers = new Headers(init.headers);
    if (!headers.has("content-type")) {
      headers.set("content-type", "application/json");
    }
    return new Response(text, { ...init, headers });
  }

  static redirect(url: string | URL, status = 302): Response {
    if (![301, 302, 303, 307, 308].includes(status)) {
      throw new RangeError(`${status} is not a redirect status`);
    }
    const headers = guard(new Headers({ location: new URL(String(url)).href }), "immutable");
    return new Response(null, { [internal]: { type: "default", url: "", redirected: false, status, statusText: "", headers, source: null } } as ResponseInit);
  }

  get [Symbol.toStringTag](): string {
    return "Response";
  }
}

const basic = (url: string, status: number, statusText: string, headers: Headers, source: Source | null, extra: Partial<ResponseFields> = {}) =>
  new Response(null, { [internal]: { type: "basic", url, redirected: false, status, statusText, headers: guard(headers, "immutable"), source, ...extra } } as ResponseInit);

const percentDecode = (text: string): Uint8Array => {
  const bytes = new TextEncoder().encode(text);
  const out = new Uint8Array(bytes.length);
  let written = 0;
  const hex = (byte: number) => byte >= 0x30 && byte <= 0x39 ? byte - 0x30 : (byte | 0x20) >= 0x61 && (byte | 0x20) <= 0x66 ? (byte | 0x20) - 0x57 : -1;
  for (let index = 0; index < bytes.length; index++) {
    const high = bytes[index] === 0x25 ? hex(bytes[index + 1]) : -1;
    const low = high >= 0 ? hex(bytes[index + 2]) : -1;
    if (low >= 0) {
      out[written++] = (high << 4) | low;
      index += 2;
    } else {
      out[written++] = bytes[index];
    }
  }
  return out.slice(0, written);
};

const dataResponse = (url: URL): Response => {
  const href = url.href.replace(/#.*$/s, "");
  const content = href.slice("data:".length);
  const comma = content.indexOf(",");
  if (comma < 0) {
    throw new TypeError("the data: URL has no comma");
  }
  let type = content.slice(0, comma).replace(/^[\t\n\f\r ]+|[\t\n\f\r ]+$/g, "");
  let bytes = percentDecode(content.slice(comma + 1));
  const base64 = /;[\t\n\f\r ]*base64[\t\n\f\r ]*$/i.exec(type);
  if (base64) {
    type = type.slice(0, base64.index);
    let decoded: string;
    try {
      decoded = atob(new TextDecoder().decode(bytes));
    } catch {
      throw new TypeError("the data: URL is not valid base64");
    }
    bytes = Uint8Array.from(decoded, character => character.charCodeAt(0));
  }
  type = type.replace(/[\t\n\f\r ;]+$/, "");
  if (type.startsWith(";")) {
    type = `text/plain${type}`;
  }
  if (!/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+\/[!#$%&'*+\-.^_`|~0-9A-Za-z]+/.test(type)) {
    type = "text/plain;charset=US-ASCII";
  }
  return basic(href, 200, "OK", new Headers({ "content-type": type }), { bytes });
};

const blobResponse = (url: URL, method: string): Response => {
  const blob = objectURL(url.href);
  if (method !== "GET" || blob === undefined) {
    throw new TypeError(blob === undefined ? `the blob URL ${url.href} was revoked or never created` : "a blob URL can only be fetched with GET");
  }
  return basic(url.href.replace(/#.*$/s, ""), 200, "OK", new Headers({ "content-type": blob.type, "content-length": String(blob.size) }), { bytes: blobBytes(blob).slice() });
};

interface Fetched {
  request: string;
  status: number;
  statusText: string;
  url: string;
  redirected: boolean;
  headers: [string, string][];
  body: string;
}

export async function fetch(input: string | URL | Request, init?: RequestInit): Promise<Response> {
  const request = new Request(input, init);
  const { signal } = request;
  signal.throwIfAborted();
  const url = new URL(request.url);
  switch (url.protocol) {
    case "data:":
      return dataResponse(url);
    case "blob:":
      return blobResponse(url, request.method);
    case "http:":
    case "https:":
      break;
    default:
      throw new TypeError(`fetch supports http:, https:, data: and blob:, not ${url.protocol}`);
  }
  const source = takeBody(stateOf(request));
  let body = "";
  let stream = "";
  if (source !== null && "bytes" in source) {
    body = native.put(source.bytes);
  } else if (source !== null) {
    const id = takeNative(source.stream);
    if (id !== null) {
      stream = id;
    } else {
      const [reader, writer] = native.pipe();
      stream = reader;
      const accept = (chunk: unknown) => {
        if (!(chunk instanceof Uint8Array)) {
          throw new TypeError("the request body stream produced a chunk that is not a Uint8Array");
        }
        return chunk;
      };
      source.stream.pipeTo(nativeWritable(writer, accept), { signal }).catch(() => {});
    }
  }
  let fetched: Fetched;
  try {
    fetched = await invoke<Fetched>("fetch", [{ url: request.url, method: request.method, headers: headerList(request.headers), body, stream, redirect: request.redirect }], { signal });
  } catch (error) {
    if (stream !== "") {
      native.release(stream, "the request failed");
    }
    throw error;
  }
  const headers = new Headers(fetched.headers);
  if (fetched.body === "") {
    return basic(new URL(fetched.url).href, fetched.status, fetched.statusText, headers, null, { redirected: fetched.redirected });
  }
  const abort = () => {
    errorNative(readable, signal.reason);
    native.release(fetched.request, failureOf(signal.reason));
  };
  const readable = nativeReadable(fetched.body, () => signal.removeEventListener("abort", abort));
  signal.addEventListener("abort", abort, { once: true });
  return basic(new URL(fetched.url).href, fetched.status, fetched.statusText, headers, { stream: readable }, { redirected: fetched.redirected, signal });
}
