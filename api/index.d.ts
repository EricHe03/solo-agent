export interface CallOptions {
  readonly signal?: AbortSignal;
}

export interface ObservableState<T> {
  get(options?: CallOptions): Promise<T>;
  values(options?: CallOptions): AsyncIterable<T>;
}

export type Point = [x: number, y: number];
export type Rect = [x: number, y: number, width: number, height: number];
export type Quad = [topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point];

export type ErrorName = "AbortError" | "TimeoutError" | "NotFoundError" | "UnavailableError";

export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

export type Jsonify<T> = T extends string | number | boolean | null ? T
  : T extends undefined | symbol | ((...args: any[]) => unknown) ? never
  : T extends { toJSON(): infer J } ? Jsonify<J>
  : T extends readonly (infer U)[] ? Jsonify<U>[]
  : T extends object ? { [K in keyof T]: Jsonify<Exclude<T[K], undefined>> }
  : never;

declare global {
  function sleep(ms: number, options?: CallOptions): Promise<void>;
}
