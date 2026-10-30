export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

export type Jsonify<T> = T extends string | number | boolean | null ? T
  : T extends undefined | symbol | ((...args: any[]) => unknown) ? never
  : T extends { toJSON(): infer J } ? Jsonify<J>
  : T extends readonly (infer U)[] ? Jsonify<U>[]
  : T extends object ? { [K in keyof T]: Jsonify<Exclude<T[K], undefined>> }
  : never;

export type Caller = "app" | "shortcuts" | "api";

declare const types: unique symbol;

export interface Action<Input = void, Output = void> {
  readonly [types]: { input: Input; output: Output };
  readonly title: string;
  readonly description?: string;
  readonly expose: readonly "shortcuts"[];
}

export interface Extension<Actions extends Record<string, Action<any, any>> = {}> {
  readonly actions: Actions;
}

export type ServiceStatus = "starting" | "running" | "stopped" | "failed";
