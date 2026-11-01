import { registerRootComponent, requireNativeModule, type EventSubscription } from "expo";
import { Component, useEffect, useMemo, useSyncExternalStore, useState, type ComponentType, type ReactNode } from "react";

import { inspect } from "../shared/inspect";
import { directoryOf, type FileHost } from "./files";

type ServiceStatus = "starting" | "running" | "stopped" | "failed";

interface ServiceEvent {
  enabled: boolean;
  status: ServiceStatus;
  error: string;
  since: number;
}

interface Service {
  enabled: boolean;
  status: ServiceStatus;
  error: string | null;
  since: Date | null;
}

interface Props {
  surface: string;
  name: string;
  file: string;
  source: string;
  dataDirectory: string;
  assetsDirectory: string;
  service: ServiceEvent;
}

interface SwiptHost extends FileHost {
  call(swiplet: string, action: string, input: string): Promise<string>;
  setServiceEnabled(swiplet: string, enabled: boolean): Promise<void>;
  mounted(surface: string): void;
  exit(swiplet: string): void;
  preferredLocalizations(localizations: string[]): string[];
  log(swiplet: string, level: string, message: string): void;
  fail(surface: string, message: string): void;
  report(swiplet: string, message: string): void;
  addListener(event: "service", listener: (event: ServiceEvent & { name: string }) => void): EventSubscription;
}

interface State {
  service: Service;
  listeners: Set<() => void>;
}

const host = requireNativeModule<SwiptHost>("SwiptHost");
const states = new Map<string, State>();

const stateOf = (name: string): State => {
  let state = states.get(name);
  if (state === undefined) {
    state = { service: { enabled: false, status: "stopped", error: null, since: null }, listeners: new Set() };
    states.set(name, state);
  }
  return state;
};

const serviceOf = (event: ServiceEvent): Service => ({
  enabled: Boolean(event.enabled), status: event.status, error: event.error || null, since: event.since > 0 ? new Date(event.since) : null,
});

host.addListener("service", event => {
  const state = stateOf(event.name);
  state.service = serviceOf(event);
  for (const listener of state.listeners) {
    listener();
  }
});

const describe = (error: unknown): string => (error instanceof Error ? String(error.stack ?? `${error.name}: ${error.message}`) : `Uncaught ${inspect(error)}`);

const messageOf = (error: unknown): string => (error instanceof Error ? error.message || error.name : inspect(error));

const format = (value: unknown): string => (typeof value === "string" ? value : value instanceof Error ? describe(value) : inspect(value));

const swipletOf = (error: unknown): string => (error instanceof Error && /\bswiplet:\/\/([^/]+)\//.exec(String(error.stack))?.[1]) || "";

const reportFor = (swiplet: string) => (error: unknown) => {
  host.log(swiplet, "error", describe(error));
  host.report(swiplet, messageOf(error));
};

const report = (error: unknown) => reportFor(swipletOf(error))(error);

const fail = (name: string, surface: string, error: unknown) => {
  host.log(name, "error", describe(error));
  host.fail(surface, messageOf(error));
};

const exceptions = (require("react-native/Libraries/Core/ExceptionsManager") as { default: { handleException(error: unknown, isFatal: boolean): void } }).default;

exceptions.handleException = (error, isFatal) => {
  if (isFatal || !(error as { isComponentError?: boolean }).isComponentError) {
    report(error);
  }
};

(console as { reportErrorsAsExceptions?: boolean }).reportErrorsAsExceptions = false;

for (const [method, level] of [["log", "info"], ["info", "info"], ["warn", "warn"], ["error", "error"], ["debug", "debug"]] as const) {
  const original = console[method];
  console[method] = (...values: unknown[]) => {
    original(...values);
    host.log(swipletOf(new Error()), level, values.map(format).join(" "));
  };
}

(HermesInternal as { enablePromiseRejectionTracker?: (options: { allRejections: boolean; onUnhandled: (id: number, error: unknown) => void }) => void } | null)
  ?.enablePromiseRejectionTracker?.({ allRejections: true, onUnhandled: (_, error) => report(error) });

const consoleOf = (name: string) => {
  const print = (level: string) => (...values: unknown[]) => host.log(name, level, values.map(format).join(" "));
  return Object.freeze({ log: print("info"), info: print("info"), warn: print("warn"), error: print("error"), debug: print("debug") });
};

const exportsOf = (specifier: string, values: Record<string, unknown>) =>
  new Proxy({ __esModule: true, ...values }, {
    get: (target, key) => {
      if (typeof key === "string" && key !== "then" && !(key in target)) {
        throw new Error(`${specifier} has no export "${key}"`);
      }
      return Reflect.get(target, key);
    },
  });

const abortError = (signal: AbortSignal): unknown => signal.reason ?? Object.assign(new Error("the call was aborted"), { name: "AbortError" });

const preferredLocalizations = (localizations: readonly string[]): string[] => {
  if (!Array.isArray(localizations) || !localizations.every(localization => typeof localization === "string")) {
    throw new TypeError("the localizations must be an array of strings");
  }
  return host.preferredLocalizations([...localizations]);
};

function interfaceModule({ name, service }: Props) {
  const state = stateOf(name);
  state.service = serviceOf(service);
  const subscribe = (listener: () => void) => {
    state.listeners.add(listener);
    return () => {
      state.listeners.delete(listener);
    };
  };
  const call = (action: string, input: unknown, options: { signal?: AbortSignal } = {}): Promise<unknown> => {
    const { signal } = options;
    if (signal?.aborted) {
      return Promise.reject(abortError(signal));
    }
    const reply = host.call(name, action, JSON.stringify(input === undefined ? null : input)).then(value => (value ? JSON.parse(value) : undefined));
    if (signal === undefined) {
      return reply;
    }
    return new Promise((resolve, reject) => {
      const abort = () => reject(abortError(signal));
      signal.addEventListener("abort", abort, { once: true });
      reply.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
    });
  };
  const calls = new Proxy({} as Record<string, unknown>, {
    get: (_, action) => (typeof action !== "string" || action === "then" ? undefined : (input?: unknown, options?: { signal?: AbortSignal }) => call(action, input, options)),
  });
  const setEnabled = (enabled: boolean) => host.setServiceEnabled(name, Boolean(enabled));
  const useService = () => {
    const current = useSyncExternalStore(subscribe, () => state.service);
    return useMemo(() => ({ ...current, setEnabled }), [current]);
  };
  return exportsOf("@swipt/api/swiplet", { actions: () => calls, useService, exit: () => host.exit(name), preferredLocalizations });
}

const modules: Record<string, () => unknown> = {
  react: () => require("react"),
  "react/jsx-runtime": () => require("react/jsx-runtime"),
  "react-native": () => require("react-native"),
  "react-native-worklets": () => require("react-native-worklets"),
  expo: () => require("expo"),
  "expo-localization": () => require("expo-localization"),
  "@expo/ui": () => require("@expo/ui"),
  "@expo/ui/swift-ui": () => require("@expo/ui/swift-ui"),
  "@expo/ui/swift-ui/modifiers": () => require("@expo/ui/swift-ui/modifiers"),
  "@expo/ui/community/bottom-sheet": () => require("@expo/ui/community/bottom-sheet"),
  "@expo/ui/community/datetime-picker": () => require("@expo/ui/community/datetime-picker"),
  "@expo/ui/community/masked-view": () => require("@expo/ui/community/masked-view"),
  "@expo/ui/community/menu": () => require("@expo/ui/community/menu"),
  "@expo/ui/community/pager-view": () => require("@expo/ui/community/pager-view"),
  "@expo/ui/community/picker": () => require("@expo/ui/community/picker"),
  "@expo/ui/community/segmented-control": () => require("@expo/ui/community/segmented-control"),
  "@expo/ui/community/slider": () => require("@expo/ui/community/slider"),
};

function load(props: Props): ComponentType {
  const own: Record<string, () => unknown> = {
    "@swipt/api": () => exportsOf("@swipt/api", {}),
    "@swipt/api/swiplet": () => interfaceModule(props),
    "@swipt/api/file-system": () =>
      exportsOf("@swipt/api/file-system", {
        dataDirectory: directoryOf(host, props.name, "data", props.dataDirectory),
        assets: directoryOf(host, props.name, "assets", props.assetsDirectory),
      }),
  };
  const resolve = (specifier: string) => {
    const module = own[specifier] ?? modules[specifier];
    if (module === undefined) {
      throw new Error(`Swipt doesn't provide "${specifier}"; bundle it into ${props.file}`);
    }
    return module();
  };
  const module: { exports: { default?: ComponentType } & Record<string, unknown> } = { exports: {} };
  new Function("require", "module", "exports", "console", "reportError", `${props.source}\n//# sourceURL=swiplet://${props.name}/${props.file}`)(
    resolve,
    module,
    module.exports,
    consoleOf(props.name),
    reportFor(props.name),
  );
  return module.exports.default ?? (module.exports as unknown as ComponentType);
}

class Boundary extends Component<{ name: string; surface: string; children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: unknown) {
    fail(this.props.name, this.props.surface, error);
  }

  render() {
    return this.state.failed ? null : this.props.children;
  }
}

function Root(props: Props) {
  const [loaded] = useState((): { Swiplet: ComponentType } | { error: unknown } => {
    try {
      return { Swiplet: load(props) };
    } catch (error) {
      return { error };
    }
  });
  useEffect(() => {
    if ("error" in loaded) {
      fail(props.name, props.surface, loaded.error);
    }
    host.mounted(props.surface);
  }, [loaded, props.name, props.surface]);
  if ("error" in loaded) {
    return null;
  }
  const { Swiplet } = loaded;
  return (
    <Boundary name={props.name} surface={props.surface}>
      <Swiplet />
    </Boundary>
  );
}

registerRootComponent(Root);
