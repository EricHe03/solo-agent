import { invoke, stream } from "./async";
import { File } from "./files";

type Options = { signal?: AbortSignal };

const check = (value: unknown, allowed: string[]): Record<string, unknown> => {
  if (value === undefined) {
    return {};
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError("expected an options object");
  }
  for (const key of Object.keys(value)) {
    if (key !== "signal" && !allowed.includes(key)) {
      throw new TypeError(`unknown option ${JSON.stringify(key)}; the options are ${["signal", ...allowed].join(", ")}`);
    }
  }
  return value as Record<string, unknown>;
};

const signalOf = (value: unknown): AbortSignal | undefined => (value as Options | undefined)?.signal;

const point = (value: unknown, name: string): [number, number] => {
  if (!Array.isArray(value) || value.length !== 2 || !value.every(Number.isFinite)) {
    throw new TypeError(`${name} must be [x, y] of finite numbers`);
  }
  return value as [number, number];
};

const optionsOf = (value: unknown, allowed: string[]) => {
  const { signal: _, ...rest } = check(value, allowed);
  return rest;
};

export const act = async (operation: string, args: unknown[], options: unknown): Promise<void> => {
  await invoke(operation, args, { signal: signalOf(options) });
};

const state = <T>(name: string) => Object.freeze({
  get: (options?: Options) => invoke<T>("device.state", [name], { signal: signalOf(check(options, [])) }),
  values: (options?: Options) => stream<T>("device.state", [name], signalOf(check(options, [])), "latest"),
});

const button = (name: string) => (options?: Options) => act("device.button", [name], check(options, []));

const bundleIdOf = (bundleId: unknown): string => {
  if (typeof bundleId !== "string") {
    throw new TypeError("the bundle ID must be a string");
  }
  return bundleId;
};

export const device = Object.freeze({
  info: (options?: Options) => invoke("device.info", [], { signal: signalOf(check(options, [])) }),
  foreground: state<string>("foreground"),
  locked: state<boolean>("locked"),
  display: state<string>("display"),
  appEvents: (options?: Options) => stream("device.appEvents", [], signalOf(check(options, [])), "all", value => Object.freeze(value)),
  unlock: (options?: Options) => act("device.unlock", [], check(options, [])),

  tap: (at: unknown, options?: Options) => act("device.tap", [point(at, "the point"), optionsOf(options, ["count", "holdMs"])], options),
  swipe: (from: unknown, to: unknown, options?: Options) =>
    act("device.swipe", [point(from, "from"), point(to, "to"), optionsOf(options, ["durationMs"])], options),
  drag: (from: unknown, to: unknown, options?: Options) =>
    act("device.drag", [point(from, "from"), point(to, "to"), optionsOf(options, ["durationMs", "pressMs"])], options),
  pinch: (center: unknown, scale: number, options?: Options) =>
    act("device.pinch", [point(center, "the center"), scale, optionsOf(options, ["durationMs"])], options),
  touch: (fingers: unknown, options?: Options) => act("device.touch", [fingers], check(options, [])),
  pressKey: (combo: string, options?: Options) => {
    if (typeof combo !== "string") {
      throw new TypeError("the key combination must be a string");
    }
    return act("device.pressKey", [combo], check(options, []));
  },
  pressHome: button("home"),
  openAppSwitcher: button("appSwitcher"),
  pressPower: button("power"),
  pressVolumeUp: button("volumeUp"),
  pressVolumeDown: button("volumeDown"),

  apps: (options?: Options) => invoke("device.apps", [], { signal: signalOf(check(options, [])) }),
  appIcon: async (bundleId: string, options?: Options) =>
    new File(await invoke<string>("device.appIcon", [bundleIdOf(bundleId)], { signal: signalOf(check(options, [])) })),
  launch: (bundleId: string, options?: Options) => act("device.launch", [bundleIdOf(bundleId), optionsOf(options, ["url", "restart"])], options),

  clipboard: (options?: Options) => invoke<string | null>("device.clipboard", [], { signal: signalOf(check(options, [])) }),
  setClipboard: (text: string | null, options?: Options) => {
    if (text !== null && typeof text !== "string") {
      throw new TypeError("the text must be a string or null");
    }
    return act("device.setClipboard", [text], check(options, []));
  },

  setLocation: (latitude: number, longitude: number, options?: Options) =>
    act("device.setLocation", [latitude, longitude], check(options, [])),
  clearLocation: (options?: Options) => act("device.clearLocation", [], check(options, [])),
});

export { check, signalOf, optionsOf };
