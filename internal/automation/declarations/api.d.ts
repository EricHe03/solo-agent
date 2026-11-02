interface CallOptions {
  readonly signal?: AbortSignal;
}

interface ObservableState<T> {
  get(options?: CallOptions): Promise<T>;
  values(options?: CallOptions): AsyncIterable<T>;
}

type Point = [x: number, y: number];
type Rect = [x: number, y: number, width: number, height: number];
type Quad = [topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point];

type ErrorName = "AbortError" | "TimeoutError" | "NotFoundError" | "UnavailableError";

type JSONValue = string | number | boolean | null | JSONValue[] | { [key: string]: JSONValue };

type Jsonify<T> = T extends string | number | boolean | null ? T
  : T extends undefined | symbol | ((...args: any[]) => unknown) ? never
  : T extends { toJSON(): infer J } ? Jsonify<J>
  : T extends readonly (infer U)[] ? Jsonify<U>[]
  : T extends object ? { [K in keyof T]: Jsonify<Exclude<T[K], undefined>> }
  : never;

declare function sleep(ms: number, options?: CallOptions): Promise<void>;

declare const dataDirectory: DirectoryHandle;

interface FileStat {
  readonly size: number;
  readonly modified: number;
}

interface DirectoryHandle {
  readonly uri: string;
  readonly name: string;
  file(path: string): FileHandle;
  directory(path: string): DirectoryHandle;
  exists(): Promise<boolean>;
  create(): Promise<void>;
  list(): Promise<(FileHandle | DirectoryHandle)[]>;
  delete(): Promise<void>;
}

interface FileHandle {
  readonly uri: string;
  readonly name: string;
  stat(): Promise<FileStat | null>;
  text(): Promise<string>;
  bytes(): Promise<Uint8Array>;
  write(data: string | Uint8Array | Blob): Promise<void>;
  copy(to: FileHandle): Promise<void>;
  move(to: FileHandle): Promise<void>;
  delete(): Promise<void>;
}

type IntentChoiceStyle = "default" | "destructive" | "cancel";

type ConfirmationActionName = "add" | "addData" | "book" | "buy" | "call" | "checkIn" | "continue" | "create" | "do" | "download"
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

interface IntentDialog {
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

declare namespace accessibility {
  export type AccessibilityTrait = "button" | "link" | "image" | "playsSound" | "keyboardKey" | "staticText" | "summaryElement"
    | "updatesFrequently" | "searchField" | "startsMediaSession" | "adjustable" | "allowsDirectInteraction"
    | "causesPageTurn" | "tabBar" | "header" | "webContent" | "textEntry";

  export type AccessibilityAction = "press" | "increment" | "decrement" | "escape" | "menu"
    | "scrollUp" | "scrollDown" | "scrollLeft" | "scrollRight" | "scrollToVisible";

  export interface AccessibilityElement {
    readonly role: string;
    readonly class?: string;
    readonly traits: readonly AccessibilityTrait[];
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
    readonly children: readonly AccessibilityElement[];
    readonly parent?: AccessibilityElement;
    find(selector: AccessibilitySelector): AccessibilityElement | null;
    findAll(selector: AccessibilitySelector): AccessibilityElement[];
  }

  export interface AccessibilitySnapshot {
    readonly app: string;
    readonly time: number;
    readonly root: AccessibilityElement;
    readonly system?: AccessibilityElement;
    find(selector: AccessibilitySelector): AccessibilityElement | null;
    findAll(selector: AccessibilitySelector): AccessibilityElement[];
  }

  type TextField = "role" | "class" | "label" | "value" | "identifier" | "placeholder" | "hint" | "url" | "app";
  type Flag = "disabled" | "focused" | "selected" | "expanded" | "secure" | "partial" | "offScreen" | "inert" | "remote";

  export type AccessibilitySelector =
    | ({ traits?: AccessibilityTrait[]; within?: AccessibilitySelector | AccessibilityElement; parent?: AccessibilitySelector | AccessibilityElement; has?: AccessibilitySelector | AccessibilityElement; not?: AccessibilitySelector | AccessibilityElement; index?: number }
      & { [field in TextField]?: string | RegExp }
      & { [field in Flag]?: boolean })
    | ((element: AccessibilityElement) => boolean);

  export interface SnapshotOptions extends CallOptions {
    readonly scope?: "frontApp" | "screen";
    readonly full?: boolean;
  }

  export interface FindOptions extends CallOptions {
    /** Omitted or 0 reads once; a positive number or Infinity reads until a match, and answers null at the limit. */
    readonly timeoutMs?: number;
    /** Reads again as soon as a read ends. Without it, a read waits for the device's next screen push, which comes 0.75 s after a change at the soonest and not at all for a change that adds or removes no element. */
    readonly poll?: boolean;
    readonly pollTimeoutMs?: number;
  }

  export function snapshot(options?: SnapshotOptions): Promise<AccessibilitySnapshot>;
  export function find(selector: AccessibilitySelector | readonly AccessibilitySelector[], options?: FindOptions): Promise<AccessibilityElement | null>;
  export interface ElementOptions extends CallOptions {
    /** Omitted or 0 tries once; a positive number or Infinity keeps checking until a tap would reach the element, and fails at the limit. */
    readonly timeoutMs?: number;
  }

  export function tap(element: AccessibilityElement, options?: ElementOptions): Promise<void>;
  export function setText(element: AccessibilityElement, text: string, options?: ElementOptions): Promise<void>;
  export function perform(element: AccessibilityElement, action: AccessibilityAction | (string & {}), options?: CallOptions): Promise<void>;
}

declare namespace input {
  export interface TapOptions extends CallOptions {
    readonly count?: number;
  }

  export type KeyboardKey = "return" | "backspace" | "forwardDelete" | "tab" | "escape" | "space" | "left" | "right" | "up" | "down"
    | "home" | "end" | "pageUp" | "pageDown" | `f${1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12}`;
  export type KeyboardModifier = "cmd" | "shift" | "ctrl" | "alt";
  export type KeyCombination = KeyboardKey | `${KeyboardModifier}+${KeyboardKey}` | (string & {});
  export type TouchSample = [x: number, y: number, ms: number];

  export function tap(point: Point, options?: TapOptions): Promise<void>;
  export function swipe(from: Point, to: Point, options?: CallOptions & { durationMs?: number }): Promise<void>;
  export function drag(from: Point, to: Point, options?: CallOptions & { durationMs?: number; pressMs?: number }): Promise<void>;
  export function pinch(center: Point, scale: number, options?: CallOptions & { durationMs?: number }): Promise<void>;
  export function touch(fingers: readonly (readonly TouchSample[])[], options?: CallOptions): Promise<void>;
  export function pressKey(combination: KeyCombination, options?: CallOptions): Promise<void>;
  export function pressHome(options?: CallOptions): Promise<void>;
  export function openAppSwitcher(options?: CallOptions): Promise<void>;
  export function pressPower(options?: CallOptions): Promise<void>;
  export function pressVolumeUp(options?: CallOptions): Promise<void>;
  export function pressVolumeDown(options?: CallOptions): Promise<void>;
}

declare namespace device {
  export type DisplayState = "off" | "dimmed" | "inactiveOn" | "activeOn";

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

  export interface InstalledApplication {
    readonly bundleId: string;
    readonly name: string;
    readonly version?: string;
    readonly build?: string;
  }

  export interface ApplicationStateEvent {
    readonly type: "launch" | "foreground" | "background";
    readonly bundleId: string;
    readonly pid: number;
    readonly time: number;
  }

  export function info(options?: CallOptions): Promise<DeviceInfo>;
  export const foregroundApplication: ObservableState<string>;
  export const locked: ObservableState<boolean>;
  export const displayState: ObservableState<DisplayState>;
  export function unlock(options?: CallOptions): Promise<void>;

  export function applicationEvents(options?: CallOptions): AsyncIterable<ApplicationStateEvent>;
  export function installedApplications(options?: CallOptions): Promise<InstalledApplication[]>;
  export function applicationIcon(bundleId: string, options?: CallOptions): Promise<FileHandle>;
  export function launchApplication(bundleId: string, options?: CallOptions & { url?: string; restart?: boolean }): Promise<void>;

  export function pasteboard(options?: CallOptions): Promise<string | null>;
  export function setPasteboard(text: string | null, options?: CallOptions): Promise<void>;

  export function simulateLocation(latitude: number, longitude: number, options?: CallOptions): Promise<void>;
  export function clearSimulatedLocation(options?: CallOptions): Promise<void>;
}

declare namespace screen {
  type ImageDifference = image.ImageDifference;
  type RasterImage = image.RasterImage;
  export interface WaitOptions extends CallOptions {
    readonly region?: Rect;
    readonly timeoutMs?: number;
    readonly threshold?: number;
  }

  export interface ScreenChange {
    readonly time: number;
    readonly end: number;
    readonly frames: readonly Rect[];
    readonly app: string | null;
    readonly before: RasterImage;
    readonly after: RasterImage;
  }

  export type TimelineEvent =
    | { readonly time: number; readonly type: "operation"; readonly name: string; readonly arguments?: readonly unknown[]; readonly durationMs?: number; readonly error?: string; readonly message?: string; readonly swiplet?: string }
    | { readonly time: number; readonly type: "action"; readonly swiplet: string; readonly action: string; readonly caller: "app" | "shortcuts" | "api" }
    | { readonly time: number; readonly type: "foreground"; readonly app: string }
    | { readonly time: number; readonly type: "log"; readonly swiplet: string; readonly level: "error" | "warn" | "info" | "debug"; readonly message: string }
    | { readonly time: number; readonly type: "feed"; readonly frames: number; readonly decodedMs: number };

  export interface ScreenRecording {
    readonly file: FileHandle;
    readonly start: number | null;
    readonly duration: number;
    readonly width: number;
    readonly height: number;
    readonly scale: number;
    readonly changes: readonly ScreenChange[];
    readonly events: readonly TimelineEvent[];

    frame(time: number): RasterImage;
    frames(times: readonly number[] | { readonly everyMs: number; readonly from?: number; readonly to?: number }): RasterImage[];
    grid(options?: CallOptions & { readonly times?: readonly number[]; readonly columns?: number; readonly width?: number }): Promise<RasterImage>;
    diff(from: number, to: number, options?: CallOptions & { readonly threshold?: number }): Promise<ImageDifference>;
    find(target: ScreenTarget | readonly ScreenTarget[], options?: Omit<ScreenFindOptions, "timeoutMs"> & { readonly from?: number; readonly to?: number }): Promise<(ScreenMatch & { readonly time: number }) | null>;
    export(options?: CallOptions & {
      readonly file?: FileHandle | string;
      readonly from?: number;
      readonly to?: number;
      readonly region?: Rect;
      readonly scale?: number;
      readonly format?: "mov" | "mp4" | "gif";
      readonly frameRate?: number;
    }): Promise<FileHandle>;
  }

  export interface RecordingSession {
    readonly file: FileHandle;
    readonly start: number;
    stop(options?: CallOptions): Promise<ScreenRecording>;
  }

  export type ScreenTarget = RasterImage | RegExp | string;

  export interface ScreenFindOptions extends CallOptions {
    readonly region?: Rect;
    /** Omitted or 0 reads the latest frame once; a positive number or Infinity keeps reading frames until a match, and answers null at the limit. */
    readonly timeoutMs?: number;
    readonly threshold?: number;
    readonly scales?: readonly number[];
    readonly languages?: readonly string[];
    readonly minimumHeight?: number;
    /** Compares templates and the screen as black and white, split at this gray level, so a mark keeps matching over changing backgrounds. */
    readonly binarize?: number;
  }

  export interface ScreenMatch {
    readonly frame: Rect;
    readonly center: Point;
    readonly score: number;
    readonly text: string | null;
    readonly target: number;
    readonly image: RasterImage;
  }

  export function screenshot(options?: CallOptions): Promise<RasterImage>;
  export function find(target: ScreenTarget | readonly ScreenTarget[], options?: ScreenFindOptions): Promise<ScreenMatch | null>;
  export const frames: ObservableState<RasterImage>;
  export function waitFor(predicate: (frame: RasterImage) => boolean | Promise<boolean>, options?: CallOptions & { readonly timeoutMs?: number }): Promise<RasterImage>;
  export function waitForChange(options?: WaitOptions & { readonly from?: RasterImage }): Promise<RasterImage>;
  export function waitForStable(options?: WaitOptions & { readonly durationMs?: number }): Promise<RasterImage>;
  export function record(options?: CallOptions & { readonly file?: FileHandle | string }): Promise<RecordingSession>;
  export function openRecording(file: FileHandle | string, options?: CallOptions): Promise<ScreenRecording>;
}

declare namespace image {
  export type Color = `#${string}` | readonly [red: number, green: number, blue: number];
  export type ImageFormat = "png" | "jpeg" | "heic";

  export interface TemplateMatch {
    readonly frame: Rect;
    readonly center: Point;
    readonly score: number;
    readonly scale: number;
  }

  export interface TemplateMatchOptions extends CallOptions {
    readonly threshold?: number;
    readonly region?: Rect;
    readonly scales?: readonly number[];
  }

  export interface ColorCheck {
    readonly point: Point;
    readonly color: Color;
    readonly tolerance?: number;
  }

  export interface ConnectedComponent {
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

  export interface TextRecognitionOptions extends CallOptions {
    readonly region?: Rect;
    readonly languages?: readonly string[];
    readonly detectLanguage?: boolean;
    readonly level?: "fast" | "accurate";
    readonly words?: readonly string[];
    readonly correction?: boolean;
    readonly minimumHeight?: number;
  }

  export interface RecognizedTextBox {
    readonly quad: Quad;
    readonly frame: Rect;
    readonly center: Point;
  }

  export interface RecognizedTextCandidate {
    readonly text: string;
    readonly confidence: number;
    boundingBox(start: number, end: number): RecognizedTextBox | null;
  }

  export interface RecognizedTextLine extends RecognizedTextCandidate, RecognizedTextBox {
    readonly candidates: readonly RecognizedTextCandidate[];
  }

  export interface ImageDifference {
    readonly ratio: number;
    readonly frames: readonly Rect[];
  }

  export interface DetectedBarcode {
    readonly payload: string | null;
    readonly symbology: string;
    readonly quad: Quad;
    readonly frame: Rect;
    readonly center: Point;
  }

  export interface RasterImage {
    readonly width: number;
    readonly height: number;
    readonly scale: number;
    readonly frame: Rect;
    readonly time: number | null;
    readonly timestamp: number | null;

    crop(rect: Rect): RasterImage;
    resize(scale: number): RasterImage;
    resize(size: { readonly width?: number; readonly height?: number }): RasterImage;
    rotate(degrees: number): RasterImage;
    grayscale(): RasterImage;
    threshold(level?: number | "otsu"): RasterImage;
    mask(color: Color, options?: { readonly tolerance?: number }): RasterImage;
    mask(range: readonly [low: Color, high: Color]): RasterImage;
    invert(): RasterImage;
    dilate(radius?: number): RasterImage;
    erode(radius?: number): RasterImage;

    encode(format?: ImageFormat, options?: CallOptions & { readonly quality?: number }): Promise<Uint8Array>;
    save(file: FileHandle | string, options?: CallOptions & { readonly format?: ImageFormat; readonly quality?: number }): Promise<FileHandle>;
    pixel(point: Point, options?: CallOptions): Promise<[red: number, green: number, blue: number, alpha: number]>;
    stats(options?: CallOptions & { readonly region?: Rect }): Promise<ImageStats>;

    find(template: RasterImage, options?: TemplateMatchOptions): Promise<TemplateMatch | null>;
    findAll(template: RasterImage, options?: TemplateMatchOptions & { readonly limit?: number; readonly overlap?: number }): Promise<TemplateMatch[]>;
    matchColors(checks: readonly ColorCheck[], options?: CallOptions): Promise<boolean[]>;
    components(options?: CallOptions & { readonly minimumPixels?: number }): Promise<ConnectedComponent[]>;
    recognizeText(options?: TextRecognitionOptions): Promise<RecognizedTextLine[]>;
    diff(other: RasterImage, options?: CallOptions & { readonly threshold?: number }): Promise<ImageDifference>;
    distance(other: RasterImage, options?: CallOptions): Promise<number>;
    nearest(candidates: readonly RasterImage[], options?: CallOptions): Promise<{ readonly index: number; readonly distance: number }>;
    detectBarcodes(options?: CallOptions): Promise<DetectedBarcode[]>;
  }

  export function decode(data: Uint8Array | FileHandle | string, options?: CallOptions & { readonly scale?: number }): Promise<RasterImage>;
}

declare const dialog: IntentDialog;
declare const args: readonly string[];
declare function show(image: image.RasterImage): void;
