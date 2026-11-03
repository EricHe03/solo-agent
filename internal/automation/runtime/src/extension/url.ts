import type {
  URL as ParsedURL,
  URLSearchParams as ParsedParams,
} from "whatwg-url-minimum";

import {
  brand,
  defineInterface,
  domString,
  instance,
  isObject,
  iterableMethod,
  optional,
  record,
  sequence,
  sequenceFrom,
  usvString,
} from "../shared/webidl";
import { Blob, createObjectURL, revokeObjectURL } from "./blob";
import { chunk } from "./chunks";

const adopting = Symbol("adopting");
let adoptParams: (params: ParsedParams) => object;
let entriesOf: (params: object) => [string, string][];
let inspectURL: (url: object) => [string, unknown][];

const pair = sequence(usvString);
const recordInit = record(usvString, usvString);

const paramsInit = (value: unknown, context: string): string | string[][] => {
  if (isObject(value)) {
    const method = iterableMethod(value, context);
    return method === undefined
      ? recordInit(value, context)
      : sequenceFrom(value, method, pair, context);
  }
  return usvString(value, context);
};

export const URLSearchParams = defineInterface(
  class URLSearchParams {
    readonly #params: ParsedParams;

    static [brand](value: object) {
      return #params in value;
    }

    static {
      adoptParams = (params) => new URLSearchParams(adopting, params);
    }

    constructor(
      init:
        | string
        | string[][]
        | Record<string, string>
        | globalThis.URLSearchParams
        | typeof adopting = "",
      parsed?: ParsedParams,
    ) {
      this.#params =
        init === adopting
          ? parsed!
          : new (chunk("url").URLSearchParams)(init as string);
    }

    get size(): number {
      return this.#params.size;
    }

    append(name: string, value: string): void {
      this.#params.append(name, value);
    }

    delete(name: string, value?: string): void {
      this.#params.delete(name, value);
    }

    get(name: string): string | null {
      return this.#params.get(name);
    }

    getAll(name: string): string[] {
      return this.#params.getAll(name);
    }

    has(name: string, value?: string): boolean {
      return this.#params.has(name, value);
    }

    set(name: string, value: string): void {
      this.#params.set(name, value);
    }

    sort(): void {
      this.#params.sort();
    }

    toString(): string {
      return this.#params.toString();
    }

    declare forEach: (
      callback: (value: string, key: string, parent: URLSearchParams) => void,
      thisArg?: unknown,
    ) => void;
    declare entries: () => Web.URLSearchParamsIterator<[string, string]>;
    declare keys: () => Web.URLSearchParamsIterator<string>;
    declare values: () => Web.URLSearchParamsIterator<string>;
    declare [Symbol.iterator]: () => Web.URLSearchParamsIterator<
      [string, string]
    >;

    static {
      entriesOf = (params) => [...(params as URLSearchParams).#params];
    }
  },
  {
    construct: [optional(paramsInit, "")],
    operations: {
      append: [usvString, usvString],
      delete: [usvString, optional(usvString)],
      get: [usvString],
      getAll: [usvString],
      has: [usvString, optional(usvString)],
      set: [usvString, usvString],
      sort: [],
      toString: [],
    },
    iterable: (params) => entriesOf(params),
  },
);
export type URLSearchParams = InstanceType<typeof URLSearchParams>;

const urlArguments = [usvString, optional(usvString)];

export const URL = defineInterface(
  class URL {
    readonly #url: ParsedURL;
    #searchParams: URLSearchParams | undefined;

    static [brand](value: object) {
      return #url in value;
    }

    static {
      inspectURL = (value) => {
        const url = value as URL;
        const parsed = url.#url;
        return [
          ["href", parsed.href],
          ["origin", parsed.origin],
          ["protocol", parsed.protocol],
          ["username", parsed.username],
          ["password", parsed.password],
          ["host", parsed.host],
          ["hostname", parsed.hostname],
          ["port", parsed.port],
          ["pathname", parsed.pathname],
          ["search", parsed.search],
          [
            "searchParams",
            url.#searchParams ?? new URLSearchParams(parsed.search),
          ],
          ["hash", parsed.hash],
        ];
      };
    }

    constructor(url: string | globalThis.URL, base?: string | globalThis.URL) {
      this.#url = new (chunk("url").URL)(
        url as string,
        base as string | undefined,
      );
    }

    static parse(
      url: string | globalThis.URL,
      base?: string | globalThis.URL,
    ): URL | null {
      try {
        return new URL(url, base);
      } catch {
        return null;
      }
    }

    static canParse(
      url: string | globalThis.URL,
      base?: string | globalThis.URL,
    ): boolean {
      return chunk("url").URL.canParse(
        url as string,
        base as string | undefined,
      );
    }

    static createObjectURL(blob: Blob): string {
      return createObjectURL(blob);
    }

    static revokeObjectURL(url: string): void {
      revokeObjectURL(url);
    }

    get href(): string {
      return this.#url.href;
    }

    set href(value: string) {
      this.#url.href = value;
    }

    get origin(): string {
      return this.#url.origin;
    }

    get protocol(): string {
      return this.#url.protocol;
    }

    set protocol(value: string) {
      this.#url.protocol = value;
    }

    get username(): string {
      return this.#url.username;
    }

    set username(value: string) {
      this.#url.username = value;
    }

    get password(): string {
      return this.#url.password;
    }

    set password(value: string) {
      this.#url.password = value;
    }

    get host(): string {
      return this.#url.host;
    }

    set host(value: string) {
      this.#url.host = value;
    }

    get hostname(): string {
      return this.#url.hostname;
    }

    set hostname(value: string) {
      this.#url.hostname = value;
    }

    get port(): string {
      return this.#url.port;
    }

    set port(value: string) {
      this.#url.port = value;
    }

    get pathname(): string {
      return this.#url.pathname;
    }

    set pathname(value: string) {
      this.#url.pathname = value;
    }

    get search(): string {
      return this.#url.search;
    }

    set search(value: string) {
      this.#url.search = value;
    }

    get searchParams(): URLSearchParams {
      return (this.#searchParams ??= adoptParams(
        this.#url.searchParams,
      ) as URLSearchParams);
    }

    get hash(): string {
      return this.#url.hash;
    }

    set hash(value: string) {
      this.#url.hash = value;
    }

    toJSON(): string {
      return this.#url.href;
    }

    toString(): string {
      return this.#url.href;
    }
  },
  {
    construct: urlArguments,
    operations: { toJSON: [], toString: [] },
    statics: {
      parse: urlArguments,
      canParse: urlArguments,
      createObjectURL: [instance(Blob)],
      revokeObjectURL: [domString],
    },
    setters: {
      href: usvString,
      protocol: usvString,
      username: usvString,
      password: usvString,
      host: usvString,
      hostname: usvString,
      port: usvString,
      pathname: usvString,
      search: usvString,
      hash: usvString,
    },
  },
);
export type URL = InstanceType<typeof URL>;

export { inspectURL };
