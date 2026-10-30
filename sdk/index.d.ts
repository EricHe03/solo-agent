import type { Directory } from "expo-file-system";

import type { Action, Extension, ServiceStatus } from "./shared";

export type { Action, Caller, Extension, JSONValue, Jsonify, ServiceStatus } from "./shared";

type Call<A> = A extends Action<infer Input, infer Output>
  ? [Input] extends [void]
    ? (input?: undefined, options?: { signal?: AbortSignal }) => Promise<Output>
    : (input: Input, options?: { signal?: AbortSignal }) => Promise<Output>
  : never;

export interface ExtensionHandle<E extends Extension<any>> {
  readonly actions: { readonly [K in keyof E["actions"]]: Call<E["actions"][K]> };
  readonly service: {
    readonly enabled: boolean;
    readonly status: ServiceStatus;
    readonly error: string | null;
    readonly since: Date | null;
    setEnabled(enabled: boolean): Promise<void>;
  };
}

export declare function useExtension<E extends Extension<any>>(): ExtensionHandle<E>;

export declare const dataDirectory: Directory;
