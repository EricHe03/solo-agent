type File = import("expo-file-system").File;

interface Options {
  readonly signal?: AbortSignal;
}

declare function sleep(ms: number, options?: Options): Promise<void>;

interface State<T> {
  get(options?: Options): Promise<T>;
  values(options?: Options): AsyncIterable<T>;
}

type ErrorName = "AbortError" | "TimeoutError" | "NotFoundError" | "UnavailableError";

type Point = [x: number, y: number];
type Rect = [x: number, y: number, width: number, height: number];

type Quad = [topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point];
type Color = `#${string}` | readonly [red: number, green: number, blue: number];
type ImageFormat = "png" | "jpeg" | "heic";

interface Match {
  readonly frame: Rect;
  readonly center: Point;
  readonly score: number;
  readonly scale: number;
}

interface MatchOptions extends Options {
  readonly threshold?: number;
  readonly region?: Rect;
  readonly scales?: readonly number[];
}

interface ColorCheck {
  readonly point: Point;
  readonly color: Color;
  readonly tolerance?: number;
}

interface Component {
  readonly frame: Rect;
  readonly pixels: number;
  readonly centroid: Point;
}

interface ImageStats {
  readonly mean: readonly number[];
  readonly min: readonly number[];
  readonly max: readonly number[];
  readonly deviation: readonly number[];
}

interface TextOptions extends Options {
  readonly region?: Rect;
  readonly languages?: readonly string[];
  readonly detectLanguage?: boolean;
  readonly level?: "fast" | "accurate";
  readonly words?: readonly string[];
  readonly correction?: boolean;
  readonly minimumHeight?: number;
}

interface TextBox {
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

interface TextCandidate {
  readonly text: string;
  readonly confidence: number;
  boundingBox(start: number, end: number): TextBox | null;
}

interface TextLine extends TextCandidate, TextBox {
  readonly candidates: readonly TextCandidate[];
}

interface Difference {
  readonly ratio: number;
  readonly frames: readonly Rect[];
}

interface Barcode {
  readonly payload: string | null;
  readonly symbology: string;
  readonly quad: Quad;
  readonly frame: Rect;
  readonly center: Point;
}

interface Image {
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

interface WaitOptions extends Options {
  readonly region?: Rect;
  readonly timeoutMs?: number;
  readonly threshold?: number;
}

interface Change {
  readonly time: number;
  readonly end: number;
  readonly frames: readonly Rect[];
  readonly app: string | null;
  readonly before: Image;
  readonly after: Image;
}

type TimelineEvent =
  | { readonly time: number; readonly type: "operation"; readonly name: string; readonly arguments?: readonly unknown[]; readonly durationMs?: number; readonly error?: string }
  | { readonly time: number; readonly type: "action"; readonly swiplet: string; readonly action: string; readonly caller: "app" | "shortcuts" | "api" }
  | { readonly time: number; readonly type: "foreground"; readonly app: string }
  | { readonly time: number; readonly type: "log"; readonly swiplet: string; readonly level: "error" | "warn" | "info" | "debug"; readonly message: string };

interface Video {
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

interface Recording {
  readonly file: File;
  readonly start: number;
  stop(options?: Options): Promise<Video>;
}

declare const graphics: {
  screenshot(options?: Options): Promise<Image>;
  readonly screen: State<Image>;
  decode(data: Uint8Array | File, options?: Options & { readonly scale?: number }): Promise<Image>;
  waitFor(predicate: (frame: Image) => boolean | Promise<boolean>, options?: Options & { readonly timeoutMs?: number }): Promise<Image>;
  waitForChange(options?: WaitOptions & { readonly from?: Image }): Promise<Image>;
  waitForStable(options?: WaitOptions & { readonly durationMs?: number }): Promise<Image>;
  record(options?: Options & { readonly file?: File | string }): Promise<Recording>;
  open(file: File | string, options?: Options): Promise<Video>;
};

type Display = "off" | "dimmed" | "inactiveOn" | "activeOn";

interface DeviceInfo {
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

interface AppEvent {
  readonly type: "launch" | "foreground" | "background";
  readonly bundleId: string;
  readonly pid: number;
  readonly time: number;
}

interface App {
  readonly bundleId: string;
  readonly name: string;
  readonly version?: string;
  readonly build?: string;
}

type Key = "return" | "backspace" | "forwardDelete" | "tab" | "escape" | "space" | "left" | "right" | "up" | "down"
  | "home" | "end" | "pageUp" | "pageDown" | `f${1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12}`;
type Modifier = "cmd" | "shift" | "ctrl" | "alt";

declare const device: {
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

type Trait = "button" | "link" | "image" | "playsSound" | "keyboardKey" | "staticText" | "summaryElement"
  | "updatesFrequently" | "searchField" | "startsMediaSession" | "adjustable" | "allowsDirectInteraction"
  | "causesPageTurn" | "tabBar" | "header" | "webContent" | "textEntry";

interface Element {
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

interface Snapshot {
  readonly app: string;
  readonly time: number;
  readonly root: Element;
  readonly system?: Element;
  find(selector: Selector): Element | null;
  findAll(selector: Selector): Element[];
}

type TextField = "role" | "class" | "label" | "value" | "identifier" | "placeholder" | "hint" | "url" | "app";
type Flag = "disabled" | "focused" | "selected" | "expanded" | "secure" | "partial" | "offScreen" | "inert" | "remote";

type Query = { traits?: Trait[]; within?: Query; parent?: Query; has?: Query; not?: Query; index?: number }
  & { [field in TextField]?: string | RegExp }
  & { [field in Flag]?: boolean };

type Selector =
  | ({ traits?: Trait[]; within?: Selector | Element; parent?: Selector | Element; has?: Selector | Element; not?: Selector | Element; index?: number }
    & { [field in TextField]?: string | RegExp }
    & { [field in Flag]?: boolean })
  | ((element: Element) => boolean);

interface SnapshotOptions extends Options {
  readonly scope?: "screen" | "frontApp";
  readonly full?: boolean;
}

type ElementAction = "press" | "increment" | "decrement" | "escape" | "menu"
  | "scrollUp" | "scrollDown" | "scrollLeft" | "scrollRight" | "scrollToVisible";

interface LocatorOptions extends Options {
  /** 10000 when omitted; Infinity waits without a limit. */
  readonly timeoutMs?: number;
}

interface Locator {
  tap(options?: LocatorOptions & { count?: number; holdMs?: number }): Promise<void>;
  /** Taps each element as it comes to match, once while it stays matched, and resolves when the app in front at the call leaves the front, at once if the query names only other apps. */
  tapEach(options?: Options & { count?: number; holdMs?: number }): Promise<void>;
  setText(text: string, options?: LocatorOptions): Promise<void>;
  perform(action: ElementAction | (string & {}), options?: LocatorOptions): Promise<void>;
}

declare const ui: {
  locator(query: Query | readonly Query[]): Locator;
  snapshot(options?: SnapshotOptions): Promise<Snapshot>;
  find(selector: Selector, options?: Options): Promise<Element | null>;
  tap(element: Element, options?: Options & { count?: number; holdMs?: number }): Promise<void>;
};

type ChoiceStyle = "default" | "destructive" | "cancel";

type ActionName = "add" | "addData" | "book" | "buy" | "call" | "checkIn" | "continue" | "create" | "do" | "download"
  | "filter" | "find" | "get" | "go" | "log" | "open" | "order" | "pay" | "play" | "playSound" | "post" | "request" | "run"
  | "search" | "send" | "set" | "share" | "start" | "startNavigation" | "toggle" | "turnOff" | "turnOn" | "view";

interface Person {
  readonly name: string;
  readonly handle?: { type: "phoneNumber" | "emailAddress"; value: string };
}

interface Placemark {
  readonly name?: string;
  readonly coordinate?: [latitude: number, longitude: number];
  readonly address?: string;
}

interface Dialog {
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

declare const dialog: Dialog;

declare function show(image: Image): void;
