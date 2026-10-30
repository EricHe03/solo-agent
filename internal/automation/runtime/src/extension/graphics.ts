import { stream } from "./async";
import { check, optionsOf, signalOf } from "./device";
import { DOMException } from "./errors";
import { AbortController } from "./events";
import { File, pathOf } from "./files";
import { adopt, adoptOptional, finite, freeze, graphicsNative, handleOf, Image, rectOf, run, timeoutOf, type ImageHandle, type Rect } from "./image";
import { native } from "./native";

type Options = { signal?: AbortSignal };

interface RecordingHandle {
  readonly path: string;
  readonly start: number;
}

interface VideoHandle {
  readonly info: string;
  frame(time: number): ImageHandle;
}

interface RawChange {
  time: number;
  end: number;
  before: number;
  after: number;
  frames: Rect[];
  app: string | null;
}

interface VideoInfo {
  path: string;
  start: number | null;
  duration: number;
  width: number;
  height: number;
  scale: number;
  changes: RawChange[];
  events: Record<string, unknown>[];
}

const largestFrameCount = 1000;

const fileOf = (value: unknown, name: string): string => {
  if (value instanceof File) {
    return pathOf(value.uri);
  }
  if (typeof value === "string") {
    return pathOf(value);
  }
  throw new TypeError(`${name} must be a File, a file: URI or an absolute path`);
};

const defaultFile = (folder: string, extension: string): string =>
  `${native.cacheDirectory}/${folder}/${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`;

const thresholdOf = (value: unknown): number | undefined => {
  if (value === undefined) {
    return undefined;
  }
  if (!Number.isInteger(value) || (value as number) < 1 || (value as number) > 255) {
    throw new RangeError("threshold must be an integer from 1 to 255");
  }
  return value as number;
};

const durationOf = (value: unknown, name: string, fallback: number): number => {
  if (value === undefined) {
    return fallback;
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    throw new RangeError(`${name} must be a positive number of milliseconds`);
  }
  return value;
};

const imageResult = async (result: Promise<{ image: number }>): Promise<Image> => adopt((await result).image);

const recordings = new WeakMap<Recording, RecordingHandle>();
const videos = new WeakMap<Video, VideoHandle>();

const videoOf = (id: number): Video => {
  const handle = graphicsNative().take(id);
  if (handle === null) {
    throw new DOMException("the video was released", "InvalidStateError");
  }
  return new Video(handle as VideoHandle);
};

export class Recording {
  declare readonly file: File;
  declare readonly start: number;

  constructor(handle: RecordingHandle) {
    recordings.set(this, handle);
    Object.defineProperties(this, {
      file: { value: new File(handle.path), enumerable: true },
      start: { value: handle.start, enumerable: true },
    });
    Object.freeze(this);
  }

  async stop(options?: Options): Promise<Video> {
    const result = await run<{ video: number }>("recording.stop", {}, [recordings.get(this)!], signalOf(check(options, [])));
    return videoOf(result.video);
  }

  toString(): string {
    return `Recording ${this.file.name} since ${new Date(this.start).toISOString()}`;
  }
}

export class Video {
  declare readonly file: File;
  declare readonly start: number | null;
  declare readonly duration: number;
  declare readonly width: number;
  declare readonly height: number;
  declare readonly scale: number;
  declare readonly changes: readonly object[];
  declare readonly events: readonly object[];

  constructor(handle: VideoHandle) {
    videos.set(this, handle);
    const info: VideoInfo = JSON.parse(handle.info);
    const frameAt = (time: number) => new Image(handle.frame(time));
    const changes = info.changes.map(change => {
      let before: Image | undefined;
      let after: Image | undefined;
      return Object.freeze(Object.defineProperties({ time: change.time, end: change.end, frames: freeze(change.frames), app: change.app }, {
        before: { get: () => before ??= frameAt(change.before), enumerable: true },
        after: { get: () => after ??= frameAt(change.after), enumerable: true },
      }));
    });
    Object.defineProperties(this, {
      file: { value: new File(info.path), enumerable: true },
      start: { value: info.start, enumerable: true },
      duration: { value: info.duration, enumerable: true },
      width: { value: info.width, enumerable: true },
      height: { value: info.height, enumerable: true },
      scale: { value: info.scale, enumerable: true },
      changes: { value: Object.freeze(changes), enumerable: true },
      events: { value: freeze(info.events), enumerable: true },
    });
    Object.freeze(this);
  }

  #time(value: unknown, name: string): number {
    const time = finite(value, name);
    if (time < 0 || time > this.duration) {
      throw new RangeError(`${name} must be from 0 to ${this.duration} ms`);
    }
    return time;
  }

  frame(time: number): Image {
    return new Image(videos.get(this)!.frame(this.#time(time, "the time")));
  }

  frames(times: readonly number[] | { everyMs: number; from?: number; to?: number }): Image[] {
    let chosen: number[];
    if (Array.isArray(times)) {
      chosen = times.map((time, index) => this.#time(time, `time ${index + 1}`));
    } else {
      const { everyMs, from, to } = check(times, ["everyMs", "from", "to"]) as { everyMs?: unknown; from?: unknown; to?: unknown };
      const step = durationOf(everyMs, "everyMs", 1000);
      const first = from === undefined ? 0 : this.#time(from, "from");
      const last = to === undefined ? this.duration : this.#time(to, "to");
      chosen = [];
      for (let time = first; time <= last && chosen.length <= largestFrameCount; time += step) {
        chosen.push(time);
      }
    }
    if (chosen.length > largestFrameCount) {
      throw new RangeError(`at most ${largestFrameCount} frames at a time`);
    }
    return chosen.map(time => this.frame(time));
  }

  async grid(options?: Options & { times?: readonly number[]; columns?: number; width?: number }): Promise<Image> {
    const { times, columns, width } = optionsOf(options, ["times", "columns", "width"]);
    const args: Record<string, unknown> = {};
    if (times !== undefined) {
      if (!Array.isArray(times) || times.length === 0 || times.length > 200) {
        throw new TypeError("times must be an array of 1 to 200 times");
      }
      args.times = times.map((time, index) => this.#time(time, `time ${index + 1}`));
    }
    if (columns !== undefined) {
      if (!Number.isInteger(columns) || (columns as number) < 1 || (columns as number) > 16) {
        throw new RangeError("columns must be an integer from 1 to 16");
      }
      args.columns = columns;
    }
    if (width !== undefined) {
      if (!Number.isInteger(width) || (width as number) < 32 || (width as number) > 1024) {
        throw new RangeError("width must be an integer from 32 to 1024 pixels");
      }
      args.width = width;
    }
    return imageResult(run("video.grid", args, [videos.get(this)!], signalOf(options)));
  }

  async diff(from: number, to: number, options?: Options & { threshold?: number }) {
    const { threshold } = optionsOf(options, ["threshold"]);
    const args = { from: this.#time(from, "from"), to: this.#time(to, "to"), threshold: thresholdOf(threshold) };
    return freeze(await run("video.diff", args, [videos.get(this)!], signalOf(options)));
  }

  async export(options?: Options & { file?: File | string; from?: number; to?: number; region?: Rect; scale?: number; format?: "mov" | "mp4" | "gif"; frameRate?: number }): Promise<File> {
    const { file, from, to, region, scale, format = "mp4", frameRate } = optionsOf(options, ["file", "from", "to", "region", "scale", "format", "frameRate"]);
    if (format !== "mov" && format !== "mp4" && format !== "gif") {
      throw new TypeError("the format must be mov, mp4 or gif");
    }
    const args: Record<string, unknown> = { format, path: file === undefined ? defaultFile("Exports", format) : fileOf(file, "file") };
    if (from !== undefined) {
      args.from = this.#time(from, "from");
    }
    if (to !== undefined) {
      args.to = this.#time(to, "to");
    }
    if (args.from !== undefined && args.to !== undefined && (args.to as number) <= (args.from as number)) {
      throw new RangeError("to must be after from");
    }
    if (region !== undefined) {
      args.region = rectOf(region, "region");
    }
    if (scale !== undefined) {
      if (typeof scale !== "number" || !(scale > 0 && scale <= 4)) {
        throw new RangeError("scale must be above 0 and at most 4");
      }
      args.scale = scale;
    }
    if (frameRate !== undefined) {
      if (typeof frameRate !== "number" || !(frameRate > 0 && frameRate <= 120)) {
        throw new RangeError("frameRate must be above 0 and at most 120");
      }
      args.frameRate = frameRate;
    }
    const result = await run<{ path: string }>("video.export", args, [videos.get(this)!], signalOf(options));
    return new File(result.path);
  }

  toString(): string {
    return `Video ${this.file.name} ${Math.round(this.duration) / 1000} s, ${this.changes.length} changes, ${this.events.length} events`;
  }
}

const waitArgs = (options: unknown, extra: string[]) => {
  const { region, timeoutMs, threshold, ...rest } = optionsOf(options, ["region", "timeoutMs", "threshold", ...extra]);
  return {
    rest,
    args: {
      region: region === undefined ? undefined : rectOf(region, "region"),
      timeoutMs: timeoutOf(timeoutMs),
      threshold: thresholdOf(threshold),
    } as Record<string, unknown>,
  };
};

const screen = Object.freeze({
  get: (options?: Options) => imageResult(run("screen.get", {}, [], signalOf(check(options, [])))),
  values: (options?: Options) =>
    stream<Image>("graphics.watch", () => [graphicsNative().prepare("screen.watch", "{}", [])], signalOf(check(options, [])), "latest", adoptOptional),
});

const limited = (signal: AbortSignal | undefined, timeout: number | null) => {
  const controller = new AbortController();
  const abort = () => controller.abort(signal!.reason);
  if (signal?.aborted) {
    controller.abort(signal.reason);
  }
  signal?.addEventListener("abort", abort, { once: true });
  const timer = timeout === null ? undefined : setTimeout(() => controller.abort(new DOMException(`no frame matched within ${timeout} ms`, "TimeoutError")), timeout);
  return {
    signal: controller.signal,
    done: () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
    },
  };
};

export const graphics = Object.freeze({
  screenshot: (options?: Options) => imageResult(run("screenshot", {}, [], signalOf(check(options, [])))),
  screen,
  decode: (data: Uint8Array | File, options?: Options & { scale?: number }) => {
    const { scale } = optionsOf(options, ["scale"]);
    const args: Record<string, unknown> = {};
    if (scale !== undefined) {
      if (typeof scale !== "number" || !(scale > 0 && scale <= 16)) {
        throw new RangeError("scale must be above 0 and at most 16");
      }
      args.scale = scale;
    }
    const objects: object[] = [];
    if (data instanceof Uint8Array) {
      objects.push(data);
    } else {
      args.path = fileOf(data, "the data");
    }
    return imageResult(run("decode", args, objects, signalOf(options)));
  },
  waitFor: async (predicate: (frame: Image) => boolean | Promise<boolean>, options?: Options & { timeoutMs?: number }): Promise<Image> => {
    if (typeof predicate !== "function") {
      throw new TypeError("the predicate must be a function");
    }
    const { timeoutMs } = optionsOf(options, ["timeoutMs"]);
    const limit = limited(signalOf(options), timeoutOf(timeoutMs));
    try {
      for await (const frame of screen.values({ signal: limit.signal })) {
        if (await predicate(frame)) {
          return frame;
        }
      }
    } finally {
      limit.done();
    }
    throw new DOMException("the screen stream ended", "UnavailableError");
  },
  waitForChange: (options?: Options & { region?: Rect; timeoutMs?: number; threshold?: number; from?: Image }) => {
    const { rest, args } = waitArgs(options, ["from"]);
    const objects = rest.from === undefined ? [] : [handleOf(rest.from, "from")];
    return imageResult(run("screen.waitForChange", args, objects, signalOf(options)));
  },
  waitForStable: (options?: Options & { region?: Rect; timeoutMs?: number; threshold?: number; durationMs?: number }) => {
    const { rest, args } = waitArgs(options, ["durationMs"]);
    args.durationMs = durationOf(rest.durationMs, "durationMs", 500);
    return imageResult(run("screen.waitForStable", args, [], signalOf(options)));
  },
  record: async (options?: Options & { file?: File | string }): Promise<Recording> => {
    const { file } = optionsOf(options, ["file"]);
    const path = file === undefined ? defaultFile("Recordings", "mov") : fileOf(file, "file");
    if (!path.toLowerCase().endsWith(".mov")) {
      throw new TypeError("a recording is a .mov file");
    }
    const result = await run<{ recording: number }>("record", { path }, [], signalOf(options));
    const handle = graphicsNative().take(result.recording);
    if (handle === null) {
      throw new DOMException("the recording was released", "InvalidStateError");
    }
    return new Recording(handle as RecordingHandle);
  },
  open: async (file: File | string, options?: Options): Promise<Video> => {
    const result = await run<{ video: number }>("video.open", { path: fileOf(file, "the file") }, [], signalOf(check(options, [])));
    return videoOf(result.video);
  },
});
