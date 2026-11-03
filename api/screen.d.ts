import type { CallOptions, ObservableState, Point, Rect } from "./index";
import type { FileHandle } from "./file-system";
import type { ImageDifference, RasterImage } from "./image";

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
    /** Omitted, the export goes to a new file in cacheDirectory. */
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

export declare function screenshot(options?: CallOptions): Promise<RasterImage>;
export declare function find(target: ScreenTarget | readonly ScreenTarget[], options?: ScreenFindOptions): Promise<ScreenMatch | null>;
export declare const frames: ObservableState<RasterImage>;
export declare function waitFor(predicate: (frame: RasterImage) => boolean | Promise<boolean>, options?: CallOptions & { readonly timeoutMs?: number }): Promise<RasterImage>;
export declare function waitForChange(options?: WaitOptions & { readonly from?: RasterImage }): Promise<RasterImage>;
export declare function waitForStable(options?: WaitOptions & { readonly durationMs?: number }): Promise<RasterImage>;
export declare function record(options?: CallOptions & {
  /** Omitted, the recording goes to a new file in cacheDirectory. */
  readonly file?: FileHandle | string;
}): Promise<RecordingSession>;
export declare function openRecording(file: FileHandle | string, options?: CallOptions): Promise<ScreenRecording>;
