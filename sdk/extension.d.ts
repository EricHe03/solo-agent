import type { Directory, File } from "expo-file-system";

import type { StandardJSONSchemaV1, StandardSchemaV1 } from "@standard-schema/spec";

import type { Action, Caller, Extension, Jsonify } from "./shared";

export type { Action, Caller, Extension, JSONValue, Jsonify, ServiceStatus } from "./shared";

export type Schema<Input = unknown, Output = Input> = StandardSchemaV1<Input, Output> & StandardJSONSchemaV1<Input, Output>;

export interface ActionContext {
  readonly signal: AbortSignal;
  readonly caller: Caller;
  readonly dialog: Dialog;
}

type Received<S> = S extends Schema ? StandardSchemaV1.InferOutput<S> : void;
type Sent<S> = S extends Schema ? StandardSchemaV1.InferInput<S> : void;
type Returned<S, R> = S extends Schema ? StandardSchemaV1.InferInput<S> : R;
type Delivered<S, R> = S extends Schema ? StandardSchemaV1.InferOutput<S> : R;

export declare function action<I extends Schema | undefined = undefined, O extends Schema | undefined = undefined, R = void>(definition: {
  readonly title: string;
  readonly description?: string;
  readonly input?: I;
  readonly output?: O;
  readonly expose?: readonly "shortcuts"[];
  run(input: Received<I>, context: ActionContext): Returned<O, R> | Promise<Returned<O, R>>;
}): Action<Sent<I>, Jsonify<Awaited<Delivered<O, R>>>>;

export declare function defineExtension<Actions extends Record<string, Action<any, any>> = {}>(definition: {
  run?(context: { readonly signal: AbortSignal; readonly dialog: Dialog }): Promise<void>;
  readonly actions?: Actions;
}): Extension<Actions>;

export declare const dataDirectory: Directory;

export interface Options {
  readonly signal?: AbortSignal;
}

export declare function sleep(ms: number, options?: Options): Promise<void>;

export interface State<T> {
  get(options?: Options): Promise<T>;
  values(options?: Options): AsyncIterable<T>;
}

export type ErrorName = "AbortError" | "TimeoutError" | "NotFoundError" | "UnavailableError";

export type Point = [x: number, y: number];
export type Rect = [x: number, y: number, width: number, height: number];

export type Quad = [topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point];
export type Color = `#${string}` | readonly [red: number, green: number, blue: number];
export type ImageFormat = "png" | "jpeg" | "heic";

export interface Match {
  readonly frame: Rect;
  readonly center: Point;
  readonly score: number;
  readonly scale: number;
}

export interface MatchOptions extends Options {
  readonly threshold?: number;
  readonly region?: Rect;
  readonly scales?: readonly number[];
}

export interface ColorCheck {
  readonly point: Point;
  readonly color: Color;
  readonly tolerance?: number;
}

export interface Component {
  readonly frame: Rect;
  readonly pixels: number;
  readonly centroid: Point;
}

export interface ImageStats {
  readonly mean: readonly number[];
  readonly min: readonly number[];
  readonly max: readonly number[];
  readonly deviation: readonly number[];
}

export interface TextOptions extends Options {
  readonly region?: Rect;
  readonly languages?: readonly string[];
  readonly detectLanguage?: boolean;
  readonly level?: "fast" | "accurate";
  readonly words?: readonly string[];
  readonly correction?: boolean;
  readonly minimumHeight?: number;
}

export interface TextBox {
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

export interface TextCandidate {
  readonly text: string;
  readonly confidence: number;
  boundingBox(start: number, end: number): TextBox | null;
}

export interface TextLine extends TextCandidate, TextBox {
  readonly candidates: readonly TextCandidate[];
}

export interface Difference {
  readonly ratio: number;
  readonly frames: readonly Rect[];
}

export interface Barcode {
  readonly payload: string | null;
  readonly symbology: string;
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

export interface Image {
  readonly width: number;
  readonly height: number;
  readonly scale: number;
  readonly frame: Rect;
  readonly time: number | null;

  crop(rect: Rect): Image;
  resize(scale: number): Image;
  resize(size: { readonly width?: number; readonly height?: number }): Image;
  rotate(degrees: number): Image;
  grayscale(): Image;
  threshold(level?: number | "otsu"): Image;
  mask(color: Color, options?: { readonly tolerance?: number }): Image;
  mask(range: readonly [low: Color, high: Color]): Image;
  invert(): Image;
  dilate(radius?: number): Image;
  erode(radius?: number): Image;

  encode(format?: ImageFormat, options?: Options & { readonly quality?: number }): Promise<Uint8Array>;
  save(file: File | string, options?: Options & { readonly format?: ImageFormat; readonly quality?: number }): Promise<File>;
  pixel(point: Point, options?: Options): Promise<[red: number, green: number, blue: number, alpha: number]>;
  stats(options?: Options & { readonly region?: Rect }): Promise<ImageStats>;
  release(): void;

  find(template: Image, options?: MatchOptions): Promise<Match | null>;
  findAll(template: Image, options?: MatchOptions & { readonly limit?: number; readonly overlap?: number }): Promise<Match[]>;
  matchColors(checks: readonly ColorCheck[], options?: Options): Promise<boolean[]>;
  components(options?: Options & { readonly minimumPixels?: number }): Promise<Component[]>;
  recognizeText(options?: TextOptions): Promise<TextLine[]>;
  diff(other: Image, options?: Options & { readonly threshold?: number }): Promise<Difference>;
  distance(other: Image, options?: Options): Promise<number>;
  nearest(candidates: readonly Image[], options?: Options): Promise<{ readonly index: number; readonly distance: number }>;
  detectBarcodes(options?: Options): Promise<Barcode[]>;
}

export interface WaitOptions extends Options {
  readonly region?: Rect;
  readonly timeoutMs?: number;
  readonly threshold?: number;
}

export interface Change {
  readonly time: number;
  readonly end: number;
  readonly frames: readonly Rect[];
  readonly app: string | null;
  readonly before: Image;
  readonly after: Image;
}

export type TimelineEvent =
  | { readonly time: number; readonly type: "operation"; readonly name: string; readonly arguments?: readonly unknown[]; readonly durationMs?: number; readonly error?: string }
  | { readonly time: number; readonly type: "action"; readonly swiplet: string; readonly action: string; readonly caller: "app" | "shortcuts" | "api" }
  | { readonly time: number; readonly type: "foreground"; readonly app: string }
  | { readonly time: number; readonly type: "log"; readonly swiplet: string; readonly level: "error" | "warn" | "info" | "debug"; readonly message: string };

export interface Video {
  readonly file: File;
  readonly start: number | null;
  readonly duration: number;
  readonly width: number;
  readonly height: number;
  readonly scale: number;
  readonly changes: readonly Change[];
  readonly events: readonly TimelineEvent[];

  frame(time: number): Image;
  frames(times: readonly number[] | { readonly everyMs: number; readonly from?: number; readonly to?: number }): Image[];
  grid(options?: Options & { readonly times?: readonly number[]; readonly columns?: number; readonly width?: number }): Promise<Image>;
  diff(from: number, to: number, options?: Options & { readonly threshold?: number }): Promise<Difference>;
  export(options?: Options & {
    readonly file?: File | string;
    readonly from?: number;
    readonly to?: number;
    readonly region?: Rect;
    readonly scale?: number;
    readonly format?: "mov" | "mp4" | "gif";
    readonly frameRate?: number;
  }): Promise<File>;
}

export interface Recording {
  readonly file: File;
  readonly start: number;
  stop(options?: Options): Promise<Video>;
}

export declare const graphics: {
  screenshot(options?: Options): Promise<Image>;
  readonly screen: State<Image>;
  decode(data: Uint8Array | File, options?: Options & { readonly scale?: number }): Promise<Image>;
  waitFor(predicate: (frame: Image) => boolean | Promise<boolean>, options?: Options & { readonly timeoutMs?: number }): Promise<Image>;
  waitForChange(options?: WaitOptions & { readonly from?: Image }): Promise<Image>;
  waitForStable(options?: WaitOptions & { readonly durationMs?: number }): Promise<Image>;
  record(options?: Options & { readonly file?: File | string }): Promise<Recording>;
  open(file: File | string, options?: Options): Promise<Video>;
};

export type Display = "off" | "dimmed" | "inactiveOn" | "activeOn";

export interface DeviceInfo {
  readonly name: string;
  readonly model: string;
  readonly os: string;
  readonly build: string;
  readonly language: string;
  readonly screen: {
    readonly width: number;
    readonly height: number;
    readonly scale: number;
    readonly orientation: "portrait" | "portraitUpsideDown" | "landscape";
  };
}

export interface AppEvent {
  readonly type: "launch" | "foreground" | "background";
  readonly bundleId: string;
  readonly pid: number;
  readonly time: number;
}

export interface App {
  readonly bundleId: string;
  readonly name: string;
  readonly version?: string;
  readonly build?: string;
}

export type Key = "return" | "backspace" | "forwardDelete" | "tab" | "escape" | "space" | "left" | "right" | "up" | "down"
  | "home" | "end" | "pageUp" | "pageDown" | `f${1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12}`;
export type Modifier = "cmd" | "shift" | "ctrl" | "alt";

export declare const device: {
  info(options?: Options): Promise<DeviceInfo>;
  readonly foreground: State<string>;
  readonly locked: State<boolean>;
  readonly display: State<Display>;
  appEvents(options?: Options): AsyncIterable<AppEvent>;
  unlock(options?: Options): Promise<void>;

  tap(point: Point, options?: Options & { count?: number; holdMs?: number }): Promise<void>;
  swipe(from: Point, to: Point, options?: Options & { durationMs?: number }): Promise<void>;
  drag(from: Point, to: Point, options?: Options & { durationMs?: number; pressMs?: number }): Promise<void>;
  pinch(center: Point, scale: number, options?: Options & { durationMs?: number }): Promise<void>;
  touch(fingers: [x: number, y: number, ms: number][][], options?: Options): Promise<void>;
  pressKey(combo: Key | `${Modifier}+${Key}` | (string & {}), options?: Options): Promise<void>;
  pressHome(options?: Options): Promise<void>;
  openAppSwitcher(options?: Options): Promise<void>;
  pressPower(options?: Options): Promise<void>;
  pressVolumeUp(options?: Options): Promise<void>;
  pressVolumeDown(options?: Options): Promise<void>;

  apps(options?: Options): Promise<App[]>;
  appIcon(bundleId: string, options?: Options): Promise<File>;
  launch(bundleId: string, options?: Options & { url?: string; restart?: boolean }): Promise<void>;

  clipboard(options?: Options): Promise<string | null>;
  setClipboard(text: string | null, options?: Options): Promise<void>;

  setLocation(latitude: number, longitude: number, options?: Options): Promise<void>;
  clearLocation(options?: Options): Promise<void>;
};

export type Trait = "button" | "link" | "image" | "playsSound" | "keyboardKey" | "staticText" | "summaryElement"
  | "updatesFrequently" | "searchField" | "startsMediaSession" | "adjustable" | "allowsDirectInteraction"
  | "causesPageTurn" | "tabBar" | "header" | "webContent" | "textEntry";

export interface Element {
  readonly role: string;
  readonly class?: string;
  readonly traits: readonly Trait[];
  readonly label?: string;
  readonly value?: string;
  readonly identifier?: string;
  readonly placeholder?: string;
  readonly hint?: string;
  readonly url?: string;
  readonly frame?: Rect;
  readonly point?: Point;
  readonly partial?: true;
  readonly offScreen?: true;
  readonly inert?: true;
  readonly remote?: true;
  readonly disabled?: true;
  readonly focused?: true;
  readonly selected?: true;
  readonly expanded?: boolean;
  readonly secure?: true;
  readonly selection?: [location: number, length: number];
  readonly actions?: readonly string[];
  readonly children: readonly Element[];
  readonly parent?: Element;
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
}

export interface Snapshot {
  readonly app: string;
  readonly time: number;
  readonly root: Element;
  readonly system?: Element;
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
}

type TextField = "role" | "class" | "label" | "value" | "identifier" | "placeholder" | "hint" | "url" | "app";
type Flag = "disabled" | "focused" | "selected" | "expanded" | "secure" | "partial" | "offScreen" | "inert" | "remote";

export type Query = { traits?: Trait[]; within?: Query; parent?: Query; has?: Query; not?: Query; index?: number }
  & { [field in TextField]?: string | RegExp }
  & { [field in Flag]?: boolean };

export type Selector =
  | ({ traits?: Trait[]; within?: Selector | Element; parent?: Selector | Element; has?: Selector | Element; not?: Selector | Element; index?: number }
    & { [field in TextField]?: string | RegExp }
    & { [field in Flag]?: boolean })
  | ((element: Element) => boolean);

export interface SnapshotOptions extends Options {
  readonly scope?: "screen" | "frontApp";
  readonly full?: boolean;
}

export type ElementAction = "press" | "increment" | "decrement" | "escape" | "menu"
  | "scrollUp" | "scrollDown" | "scrollLeft" | "scrollRight" | "scrollToVisible";

export interface LocatorOptions extends Options {
  /** 10000 when omitted; Infinity waits without a limit. */
  readonly timeoutMs?: number;
}

export interface Locator {
  tap(options?: LocatorOptions & { count?: number; holdMs?: number }): Promise<void>;
  /** Taps each element as it comes to match, once while it stays matched, and resolves when the app in front at the call leaves the front, at once if the query names only other apps. */
  tapEach(options?: Options & { count?: number; holdMs?: number }): Promise<void>;
  setText(text: string, options?: LocatorOptions): Promise<void>;
  perform(action: ElementAction | (string & {}), options?: LocatorOptions): Promise<void>;
}

export declare const ui: {
  locator(query: Query | readonly Query[]): Locator;
  snapshot(options?: SnapshotOptions): Promise<Snapshot>;
  find(selector: Selector, options?: Options): Promise<Element | null>;
  tap(element: Element, options?: Options & { count?: number; holdMs?: number }): Promise<void>;
};

export type ChoiceStyle = "default" | "destructive" | "cancel";

export type ActionName = "add" | "addData" | "book" | "buy" | "call" | "checkIn" | "continue" | "create" | "do" | "download"
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

export interface Dialog {
  requestChoice<T extends string | { title: string; style?: ChoiceStyle }>(choices: T[], prompt: string, options?: Options): Promise<T>;
  requestConfirmation(prompt: string, options?: Options & { actionName?: ActionName | { accept: string; deny: string; destructive?: boolean } }): Promise<void>;
  requestValue(type: "text", prompt?: string, options?: Options & { multiline?: boolean; literal?: boolean }): Promise<string>;
  requestValue(type: "integer", prompt?: string, options?: Options & { stepper?: boolean; min?: number; max?: number }): Promise<number>;
  requestValue(type: "number", prompt?: string, options?: Options & { min?: number; max?: number }): Promise<number>;
  requestValue(type: "date" | "time" | "dateTime", prompt?: string, options?: Options): Promise<Date>;
  requestValue(type: "file", prompt?: string, options?: Options): Promise<{ name: string; type: string; bytes: Uint8Array }>;
  requestValue(type: "person", prompt?: string, options?: Options): Promise<Person>;
  requestValue(type: "placemark", prompt?: string, options?: Options): Promise<Placemark>;
  requestDisambiguation(values: string[], prompt: string, options?: Options): Promise<string>;
  requestValueConfirmation(value: string, prompt: string, options?: Options): Promise<boolean>;
  continueInForeground(prompt?: string, options?: Options & { alwaysConfirm?: boolean }): Promise<void>;
}
