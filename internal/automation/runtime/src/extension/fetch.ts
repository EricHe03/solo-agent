import { invoke } from "./async";
import { bytesOf, TextDecoder, TextEncoder } from "./encoding";
import { DOMException } from "./errors";
import { native } from "./native";
import { URL, URLSearchParams } from "whatwg-url-minimum";

let blobBytes: (blob: Blob) => Uint8Array;

export class Blob {
  readonly #bytes: Uint8Array;
  readonly type: string;

  static {
    blobBytes = blob => blob.#bytes;
  }

  constructor(parts: unknown[] = [], options: { type?: string } = {}) {
    const chunks = parts.map(part => part instanceof Blob ? part.#bytes : typeof part === "string" ? new TextEncoder().encode(part) : bytesOf(part));
    const bytes = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    this.#bytes = bytes;
    this.type = /[^ -~]/.test(options.type ?? "") ? "" : (options.type ?? "").toLowerCase();
  }

  get size(): number {
    return this.#bytes.length;
  }

  slice(start?: number, end?: number, type?: string): Blob {
    return new Blob([this.#bytes.slice(start, end)], { type });
  }

  async bytes(): Promise<Uint8Array> {
    return this.#bytes.slice();
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this.#bytes.slice().buffer as ArrayBuffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.#bytes);
  }
}

type HeadersInit = Headers | Record<string, string> | Iterable<readonly [string, string]>;

const token = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

export class Headers {
  #entries: [string, string][] = [];

  constructor(init?: HeadersInit) {
    if (init instanceof Headers) {
      this.#entries = init.#entries.map(([name, value]) => [name, value]);
    } else if (init !== undefined && init !== null) {
      const pairs = Symbol.iterator in Object(init) ? [...(init as Iterable<readonly [string, string]>)] : Object.entries(init as Record<string, string>);
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

  append(name: string, value: string): void {
    this.#entries.push([this.#name(name), String(value).trim()]);
  }

  set(name: string, value: string): void {
    const key = this.#name(name);
    this.#entries = this.#entries.filter(([item]) => item !== key);
    this.#entries.push([key, String(value).trim()]);
  }

  delete(name: string): void {
    const key = this.#name(name);
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

  list(): [string, string][] {
    return this.#entries.map(([name, value]) => [name, value]);
  }
}

type BodyInit = string | ArrayBuffer | ArrayBufferView | Blob | URLSearchParams | null | undefined;

const encodeBody = (body: BodyInit, headers: Headers): Uint8Array | null => {
  if (body === null || body === undefined) {
    return null;
  }
  const contentType = (type: string) => {
    if (!headers.has("content-type")) {
      headers.set("content-type", type);
    }
  };
  if (typeof body === "string") {
    contentType("text/plain;charset=UTF-8");
    return new TextEncoder().encode(body);
  }
  if (body instanceof URLSearchParams) {
    contentType("application/x-www-form-urlencoded;charset=UTF-8");
    return new TextEncoder().encode(body.toString());
  }
  if (body instanceof Blob) {
    if (body.type) {
      contentType(body.type);
    }
    return blobBytes(body).slice();
  }
  return bytesOf(body).slice();
};

abstract class Body {
  #source: (() => Uint8Array) | null;
  #used = false;

  protected constructor(source: (() => Uint8Array) | null) {
    this.#source = source;
  }

  abstract readonly headers: Headers;

  get body(): null {
    return null;
  }

  get bodyUsed(): boolean {
    return this.#used;
  }

  protected read(): Uint8Array {
    if (this.#used) {
      throw new TypeError("the body was already read");
    }
    this.#used = true;
    return this.#source?.() ?? new Uint8Array(0);
  }

  protected peek(): (() => Uint8Array) | null {
    if (this.#used) {
      throw new TypeError("the body was already read");
    }
    const source = this.#source;
    if (source === null) {
      return null;
    }
    let bytes: Uint8Array | undefined;
    const once = () => (bytes ??= source());
    this.#source = once;
    return once;
  }

  async bytes(): Promise<Uint8Array> {
    return this.read();
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this.read().slice().buffer as ArrayBuffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.read());
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text());
  }

  async blob(): Promise<Blob> {
    return new Blob([this.read()], { type: this.headers.get("content-type") ?? "" });
  }

  async formData(): Promise<never> {
    throw new DOMException("formData() is not supported", "NotSupportedError");
  }
}

const methods = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH"];

export interface RequestInit {
  method?: string;
  headers?: HeadersInit;
  body?: BodyInit;
  signal?: AbortSignal | null;
  redirect?: "follow" | "manual" | "error";
}

export class Request extends Body {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly signal: AbortSignal;
  readonly redirect: "follow" | "manual" | "error";

  constructor(input: string | URL | Request, init: RequestInit = {}) {
    const base = input instanceof Request ? input : undefined;
    const headers = new Headers(init.headers ?? base?.headers);
    const method = init.method === undefined ? base?.method ?? "GET" : String(init.method);
    const normalized = methods.includes(method.toUpperCase()) ? method.toUpperCase() : method;
    let source: (() => Uint8Array) | null = null;
    if (init.body !== undefined && init.body !== null) {
      if (normalized === "GET" || normalized === "HEAD") {
        throw new TypeError(`a ${normalized} request can't have a body`);
      }
      const bytes = encodeBody(init.body, headers);
      source = bytes === null ? null : () => bytes;
    } else if (base) {
      source = base.peek();
    }
    super(source);
    this.url = new URL(base ? base.url : String(input)).href;
    this.method = normalized;
    this.headers = headers;
    this.signal = init.signal ?? base?.signal ?? new AbortController().signal;
    this.redirect = init.redirect ?? base?.redirect ?? "follow";
  }

  clone(): Request {
    return new Request(this);
  }

  payload(): Uint8Array | null {
    const source = this.peek();
    return source === null ? null : source();
  }
}

export interface ResponseInit {
  status?: number;
  statusText?: string;
  headers?: HeadersInit;
}

export class Response extends Body {
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;
  readonly type: "basic" | "default" | "error";
  readonly url: string;
  readonly redirected: boolean;

  constructor(body: BodyInit = null, init: ResponseInit & { url?: string; redirected?: boolean; type?: "basic" | "error"; source?: () => Uint8Array } = {}) {
    const headers = new Headers(init.headers);
    const bytes = init.source ? null : encodeBody(body, headers);
    super(init.source ?? (bytes === null ? null : () => bytes));
    const status = init.status ?? 200;
    if (init.type !== "error" && (!Number.isInteger(status) || status < 200 || status > 599)) {
      throw new RangeError(`the status ${status} is outside 200 to 599`);
    }
    this.status = status;
    this.statusText = init.statusText ?? "";
    this.headers = headers;
    this.type = init.type ?? "default";
    this.url = init.url ?? "";
    this.redirected = init.redirected ?? false;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  clone(): Response {
    const source = this.peek();
    return new Response(null, {
      status: this.status, statusText: this.statusText, headers: this.headers, url: this.url, redirected: this.redirected,
      type: this.type === "error" ? "error" : "basic", source: source ?? (() => new Uint8Array(0)),
    });
  }

  static error(): Response {
    return new Response(null, { status: 0, type: "error" });
  }

  static json(data: unknown, init: ResponseInit = {}): Response {
    const headers = new Headers(init.headers);
    if (!headers.has("content-type")) {
      headers.set("content-type", "application/json");
    }
    return new Response(JSON.stringify(data), { ...init, headers });
  }

  static redirect(url: string | URL, status = 302): Response {
    if (![301, 302, 303, 307, 308].includes(status)) {
      throw new RangeError(`${status} is not a redirect status`);
    }
    return new Response(null, { status, headers: { location: new URL(String(url)).href } });
  }
}

interface Fetched {
  status: number;
  statusText: string;
  url: string;
  redirected: boolean;
  headers: [string, string][];
  body: string;
}

export async function fetch(input: string | URL | Request, init?: RequestInit): Promise<Response> {
  const request = new Request(input, init);
  const scheme = new URL(request.url).protocol;
  if (scheme !== "http:" && scheme !== "https:") {
    throw new TypeError(`fetch supports http: and https:, not ${scheme}`);
  }
  const payload = request.payload();
  const fetched = await invoke<Fetched>("fetch", [{
    url: request.url,
    method: request.method,
    headers: request.headers.list(),
    body: payload === null ? "" : native.put(payload),
    redirect: request.redirect,
  }], { signal: request.signal });
  let body: Uint8Array | undefined;
  return new Response(null, {
    status: fetched.status, statusText: fetched.statusText, headers: fetched.headers, url: fetched.url,
    redirected: fetched.redirected, type: "basic", source: () => (body ??= fetched.body === "" ? new Uint8Array(0) : native.take(fetched.body)),
  });
}
