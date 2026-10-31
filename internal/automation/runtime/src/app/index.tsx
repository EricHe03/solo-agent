import * as SwiftUI from "@expo/ui/swift-ui";
import { registerRootComponent, requireNativeModule, type EventSubscription } from "expo";
import { Component, useEffect, useMemo, useSyncExternalStore, useState, type ComponentType, type ReactNode } from "react";
import { ScrollView, Text } from "react-native";

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

const abortError = (signal: AbortSignal): unknown => signal.reason ?? Object.assign(new Error("the call was aborted"), { name: "AbortError" });

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
  return { __esModule: true, actions: () => calls, useService };
}

function NavigationStack(props: SwiftUI.NavigationStackProps) {
  if (props.path !== undefined || props.onPathChange !== undefined) {
    throw new Error("Swipt shows swiplets inside its own navigation stack, so NavigationStack takes neither path nor onPathChange");
  }
  return <SwiftUI.NavigationStack {...props} embedded />;
}

const swiftUI = { ...SwiftUI, __esModule: true, NavigationStack };

const modules: Record<string, () => unknown> = {
  react: () => require("react"),
  "react/jsx-runtime": () => require("react/jsx-runtime"),
  "react-native": () => require("react-native"),
  expo: () => require("expo"),
  "expo-localization": () => require("expo-localization"),
  "@expo/ui": () => require("@expo/ui"),
  "@expo/ui/swift-ui": () => swiftUI,
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
    "@swipt/api": () => ({ __esModule: true }),
    "@swipt/api/swiplet": () => interfaceModule(props),
    "@swipt/api/file-system": () => ({
      __esModule: true,
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
  new Function("require", "module", "exports", `${props.source}\n//# sourceURL=${props.file}`)(resolve, module, module.exports);
  return module.exports.default ?? (module.exports as unknown as ComponentType);
}

function Failure({ error }: { error: unknown }) {
  return (
    <ScrollView contentContainerStyle={{ padding: 20 }}>
      <Text selectable style={{ color: "red", fontFamily: "Menlo", fontSize: 13 }}>
        {String((error as Error | undefined)?.stack ?? error)}
      </Text>
    </ScrollView>
  );
}

class Boundary extends Component<{ children: ReactNode }, { error: unknown }> {
  state = { error: null as unknown };

  static getDerivedStateFromError(error: unknown) {
    return { error };
  }

  render() {
    return this.state.error === null ? this.props.children : <Failure error={this.state.error} />;
  }
}

function Root(props: Props) {
  useEffect(() => host.mounted(props.surface), [props.surface]);
  const [loaded] = useState((): { Swiplet: ComponentType } | { error: unknown } => {
    try {
      return { Swiplet: load(props) };
    } catch (error) {
      return { error };
    }
  });
  if ("error" in loaded) {
    return <Failure error={loaded.error} />;
  }
  const { Swiplet } = loaded;
  return (
    <Boundary>
      <Swiplet />
    </Boundary>
  );
}

registerRootComponent(Root);
