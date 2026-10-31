import type { Raw } from "./elements";

export interface Native {
  readonly swiplet: string;
  readonly languages: string;
  readonly dataDirectory: string;
  readonly cacheDirectory: string;
  readonly extensionHead: string;
  start(id: string, name: string, args: string): void;
  cancel(id: string): void;
  failure(id: string): string;
  value(id: string): unknown;
  subscribe(id: string, kind: string, args: string): void;
  unsubscribe(id: string): void;
  print(level: string, text: string): void;
  put(data: Uint8Array): string;
  take(key: string): Uint8Array;
  random(length: number): Uint8Array;
  digest(algorithm: string, data: Uint8Array): Uint8Array;
  finish(failure: string, output: string, id?: string): void;
  show(image: Uint8Array): void;
  selector(json: string): { scripted?: boolean; failure?: string };
  match(snapshot: string, scope: string, json: string, mode: "one" | "all", call: (kind: string, id: string, value: string) => string): { elements?: Raw[]; failure?: string; thrown?: boolean };
  readonly graphics?: GraphicsNative;
}

export interface GraphicsNative {
  prepare(method: string, args: string, objects: readonly object[]): number;
  take(id: number): object | null;
  bytes(id: number): Uint8Array | null;
}

export let native: Native;

export function bind(value: Native): void {
  native = value;
}
