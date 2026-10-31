import type { Action, Extension } from "./extension";

export type ServiceStatus = "starting" | "running" | "stopped" | "failed";

type ActionCall<A> = A extends Action<infer Input, infer Output>
  ? [Input] extends [void]
    ? (input?: undefined, options?: { signal?: AbortSignal }) => Promise<Output>
    : (input: Input, options?: { signal?: AbortSignal }) => Promise<Output>
  : never;

export type ActionCalls<E extends Extension<any, any>> = { readonly [K in keyof E["actions"]]: ActionCall<E["actions"][K]> };

export interface ServiceHandle {
  readonly enabled: boolean;
  readonly status: ServiceStatus;
  readonly error: string | null;
  readonly since: Date | null;
  setEnabled(enabled: boolean): Promise<void>;
}

export declare function actions<E extends Extension<any, any>>(): ActionCalls<E>;

export declare function useService<E extends Extension<any, true>>(): ServiceHandle;
