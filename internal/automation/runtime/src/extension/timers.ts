import { check, signalOf } from "./options";

export const sleep = (ms: number, options?: { signal?: AbortSignal }): Promise<void> => {
  const signal = signalOf(check(options, []));
  if (!(Number.isFinite(ms) && ms >= 0)) {
    throw new TypeError("ms must be a non-negative number of milliseconds");
  }
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(signal.reason);
      return;
    }
    const abort = () => {
      clearTimeout(timer);
      reject(signal!.reason);
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", abort);
      resolve();
    }, ms);
    signal?.addEventListener("abort", abort, { once: true });
  });
};
