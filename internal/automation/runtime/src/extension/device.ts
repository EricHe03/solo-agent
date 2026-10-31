import { invoke, stream } from "./async";
import { handleOfPath } from "./files";
import { act, check, optionsOf, signalOf, type Options } from "./options";

const state = <T>(name: string) => Object.freeze({
  get: (options?: Options) => invoke<T>("device.state", [name], { signal: signalOf(check(options, [])) }),
  values: (options?: Options) => stream<T>("device.state", [name], signalOf(check(options, [])), "latest"),
});

const bundleIdOf = (bundleId: unknown): string => {
  if (typeof bundleId !== "string") {
    throw new TypeError("the bundle ID must be a string");
  }
  return bundleId;
};

export const info = (options?: Options) => invoke("device.info", [], { signal: signalOf(check(options, [])) });
export const foregroundApplication = state<string>("foreground");
export const locked = state<boolean>("locked");
export const displayState = state<string>("display");
export const unlock = (options?: Options) => act("device.unlock", [], check(options, []));

export const applicationEvents = (options?: Options) =>
  stream("device.applicationEvents", [], signalOf(check(options, [])), "all", value => Object.freeze(value));
export const installedApplications = (options?: Options) => invoke("device.installedApplications", [], { signal: signalOf(check(options, [])) });
export const applicationIcon = async (bundleId: string, options?: Options) =>
  handleOfPath(await invoke<string>("device.applicationIcon", [bundleIdOf(bundleId)], { signal: signalOf(check(options, [])) }));
export const launchApplication = (bundleId: string, options?: Options) =>
  act("device.launchApplication", [bundleIdOf(bundleId), optionsOf(options, ["url", "restart"])], options);

export const pasteboard = (options?: Options) => invoke<string | null>("device.pasteboard", [], { signal: signalOf(check(options, [])) });
export const setPasteboard = (text: string | null, options?: Options) => {
  if (text !== null && typeof text !== "string") {
    throw new TypeError("the text must be a string or null");
  }
  return act("device.setPasteboard", [text], check(options, []));
};

export const simulateLocation = (latitude: number, longitude: number, options?: Options) =>
  act("device.simulateLocation", [latitude, longitude], check(options, []));
export const clearSimulatedLocation = (options?: Options) => act("device.clearSimulatedLocation", [], check(options, []));
