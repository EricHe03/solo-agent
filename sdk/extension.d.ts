import type { StandardJSONSchemaV1, StandardSchemaV1 } from "@standard-schema/spec";

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

export declare function sleep(ms: number, options?: CallOptions): Promise<void>;

export type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

export type Jsonify<T> = T extends string | number | boolean | null ? T
  : T extends undefined | symbol | ((...args: any[]) => unknown) ? never
  : T extends { toJSON(): infer J } ? Jsonify<J>
  : T extends readonly (infer U)[] ? Jsonify<U>[]
  : T extends object ? { [K in keyof T]: Jsonify<Exclude<T[K], undefined>> }
  : never;

export type ActionCaller = "app" | "shortcuts" | "api";

export type Schema<Input = unknown, Output = Input> = StandardSchemaV1<Input, Output> & StandardJSONSchemaV1<Input, Output>;

declare const types: unique symbol;

export interface Action<Input = void, Output = void> {
  readonly [types]: { input: Input; output: Output };
  readonly title: string;
  readonly description?: string;
  readonly expose: readonly "shortcuts"[];
}

export interface Extension<Actions extends Record<string, Action<any, any>> = {}, HasRun extends boolean = boolean> {
  readonly [types]: { hasRun: HasRun };
  readonly actions: Actions;
}

export interface RunContext {
  readonly signal: AbortSignal;
  readonly dialog: IntentDialog;
}

export interface ActionContext extends RunContext {
  readonly caller: ActionCaller;
}

type Received<S> = S extends Schema ? StandardSchemaV1.InferOutput<S> : void;
type Sent<S> = S extends Schema ? StandardSchemaV1.InferInput<S> : void;
type Returned<S, R> = S extends Schema ? StandardSchemaV1.InferInput<S> : R;
type Delivered<S, R> = S extends Schema ? StandardSchemaV1.InferOutput<S> : R;

export declare function defineAction<I extends Schema | undefined = undefined, O extends Schema | undefined = undefined, R = void>(definition: {
  readonly title: string;
  readonly description?: string;
  readonly input?: I;
  readonly output?: O;
  readonly expose?: readonly "shortcuts"[];
  run(input: Received<I>, context: ActionContext): Returned<O, R> | Promise<Returned<O, R>>;
}): Action<Sent<I>, Jsonify<Awaited<Delivered<O, R>>>>;

export declare function defineExtension<Actions extends Record<string, Action<any, any>> = {}>(definition: {
  run(context: RunContext): Promise<void>;
  readonly actions?: Actions;
}): Extension<Actions, true>;
export declare function defineExtension<Actions extends Record<string, Action<any, any>> = {}>(definition: {
  readonly actions?: Actions;
}): Extension<Actions, false>;

export type IntentChoiceStyle = "default" | "destructive" | "cancel";

export type ConfirmationActionName = "add" | "addData" | "book" | "buy" | "call" | "checkIn" | "continue" | "create" | "do" | "download"
  | "filter" | "find" | "get" | "go" | "log" | "open" | "order" | "pay" | "play" | "playSound" | "post" | "request" | "run"
  | "search" | "send" | "set" | "share" | "start" | "startNavigation" | "toggle" | "turnOff" | "turnOn" | "view";

export interface Person {
  readonly name: string;
  readonly handle?: { type: "phoneNumber" | "emailAddress"; value: string };
}

export interface Placemark {
  readonly name?: string;
  readonly coordinate?: [latitude: number, longitude: number];
  readonly address?: string;
}

export interface IntentDialog {
  requestChoice<T extends string | { title: string; style?: IntentChoiceStyle }>(choices: T[], prompt: string, options?: CallOptions): Promise<T>;
  requestConfirmation(prompt: string, options?: CallOptions & { actionName?: ConfirmationActionName | { accept: string; deny: string; destructive?: boolean } }): Promise<void>;
  requestValue(type: "text", prompt?: string, options?: CallOptions & { multiline?: boolean; literal?: boolean }): Promise<string>;
  requestValue(type: "integer", prompt?: string, options?: CallOptions & { stepper?: boolean; min?: number; max?: number }): Promise<number>;
  requestValue(type: "number", prompt?: string, options?: CallOptions & { min?: number; max?: number }): Promise<number>;
  requestValue(type: "date" | "time" | "dateTime", prompt?: string, options?: CallOptions): Promise<Date>;
  requestValue(type: "file", prompt?: string, options?: CallOptions): Promise<{ name: string; type: string; bytes: Uint8Array }>;
  requestValue(type: "person", prompt?: string, options?: CallOptions): Promise<Person>;
  requestValue(type: "placemark", prompt?: string, options?: CallOptions): Promise<Placemark>;
  requestDisambiguation(values: string[], prompt: string, options?: CallOptions): Promise<string>;
  requestValueConfirmation(value: string, prompt: string, options?: CallOptions): Promise<boolean>;
  continueInForeground(prompt?: string, options?: CallOptions & { alwaysConfirm?: boolean }): Promise<void>;
}
