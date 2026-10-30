import { errorFrom } from "./errors";
import { native } from "./native";

interface Pending {
  resolve(value: unknown): void;
  reject(error: unknown): void;
  signal?: AbortSignal;
  release(): void;
}

interface Subscription {
  push(value: unknown): void;
  fail(error: Error): void;
}

const pending = new Map<string, Pending>();
const subscriptions = new Map<string, Subscription>();
const backlog = 1000;
let sequence = 0;

const nextID = () => String(++sequence);

export interface CallOptions {
  signal?: AbortSignal;
}

export function invoke<T>(name: string, args: unknown[], options: CallOptions = {}): Promise<T> {
  const { signal } = options;
  return new Promise<T>((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const id = nextID();
    const abort = () => native.cancel(id);
    signal?.addEventListener("abort", abort);
    pending.set(id, { resolve: resolve as (value: unknown) => void, reject, signal, release: () => signal?.removeEventListener("abort", abort) });
    native.start(id, name, JSON.stringify(args));
  });
}

export function settle(id: string): void {
  const entry = pending.get(id);
  if (entry === undefined) {
    return;
  }
  pending.delete(id);
  entry.release();
  const failure = native.failure(id);
  if (failure === "") {
    entry.resolve(native.value(id));
  } else if (entry.signal?.aborted) {
    entry.reject(entry.signal.reason);
  } else {
    entry.reject(errorFrom(JSON.parse(failure)));
  }
}

export function stream<T>(kind: string, args: unknown[] | (() => unknown[]), signal: AbortSignal | undefined, keep: "latest" | "all", decode: (value: unknown) => T | undefined = value => value as T): AsyncIterable<T> {
  return {
    [Symbol.asyncIterator](): AsyncIterator<T> {
      let id: string | undefined;
      let buffered: T[] = [];
      let waiter: { resolve(result: IteratorResult<T>): void; reject(error: unknown): void } | undefined;
      let failure: unknown;
      let done = false;
      const finish = () => {
        done = true;
        signal?.removeEventListener("abort", abort);
        if (id !== undefined) {
          subscriptions.delete(id);
          native.unsubscribe(id);
          id = undefined;
        }
      };
      const abort = () => {
        const current = waiter;
        waiter = undefined;
        finish();
        current?.reject(signal!.reason);
      };
      const fail = (error: Error) => {
        const current = waiter;
        waiter = undefined;
        finish();
        if (current) {
          current.reject(error);
        } else {
          failure = error;
        }
      };
      const open = () => {
        if (id !== undefined) {
          return;
        }
        id = nextID();
        subscriptions.set(id, {
          push: value => {
            const decoded = decode(value);
            if (decoded === undefined) {
              return;
            }
            if (waiter) {
              const current = waiter;
              waiter = undefined;
              current.resolve({ value: decoded, done: false });
            } else if (keep === "latest") {
              buffered = [decoded];
            } else if (buffered.length < backlog) {
              buffered.push(decoded);
            } else {
              fail(new Error(`the stream ended with ${backlog} events unread`));
            }
          },
          fail,
        });
        signal?.addEventListener("abort", abort);
        native.subscribe(id, kind, JSON.stringify(typeof args === "function" ? args() : args));
      };
      return {
        next(): Promise<IteratorResult<T>> {
          if (signal?.aborted) {
            finish();
            return Promise.reject(signal.reason);
          }
          if (buffered.length > 0) {
            return Promise.resolve({ value: buffered.shift()!, done: false });
          }
          if (failure !== undefined) {
            const error = failure;
            failure = undefined;
            return Promise.reject(error);
          }
          if (done) {
            return Promise.resolve({ value: undefined, done: true });
          }
          open();
          return new Promise((resolve, reject) => {
            waiter = { resolve, reject };
          });
        },
        return(): Promise<IteratorResult<T>> {
          buffered = [];
          finish();
          return Promise.resolve({ value: undefined, done: true });
        },
      };
    },
  };
}

export function deliver(id: string, json: string): void {
  subscriptions.get(id)?.push(JSON.parse(json));
}

export function end(id: string, failure: string): void {
  subscriptions.get(id)?.fail(errorFrom(JSON.parse(failure)));
}
