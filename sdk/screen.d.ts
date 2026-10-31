import type { CallOptions, ObservableState, Rect } from "./extension";
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
  | { readonly time: number; readonly type: "operation"; readonly name: string; readonly arguments?: readonly unknown[]; readonly durationMs?: number; readonly error?: string }
  | { readonly time: number; readonly type: "action"; readonly swiplet: string; readonly action: string; readonly caller: "app" | "shortcuts" | "api" }
  | { readonly time: number; readonly type: "foreground"; readonly app: string }
  | { readonly time: number; readonly type: "log"; readonly swiplet: string; readonly level: "error" | "warn" | "info" | "debug"; readonly message: string };

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

export declare function screenshot(options?: CallOptions): Promise<RasterImage>;
export declare const frames: ObservableState<RasterImage>;
export declare function waitFor(predicate: (frame: RasterImage) => boolean | Promise<boolean>, options?: CallOptions & { readonly timeoutMs?: number }): Promise<RasterImage>;
export declare function waitForChange(options?: WaitOptions & { readonly from?: RasterImage }): Promise<RasterImage>;
export declare function waitForStable(options?: WaitOptions & { readonly durationMs?: number }): Promise<RasterImage>;
export declare function record(options?: CallOptions & { readonly file?: FileHandle | string }): Promise<RecordingSession>;
export declare function openRecording(file: FileHandle | string, options?: CallOptions): Promise<ScreenRecording>;
