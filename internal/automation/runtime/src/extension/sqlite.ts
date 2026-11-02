import { createSQLite, type DatabaseChangeEvent } from "../shared/sqlite";
import { stream } from "./async";
import { DOMException } from "./errors";
import { native } from "./native";

let module: ReturnType<typeof createSQLite>["exports"] | undefined;

export const sqlite = () => module ??= createSQLite({
  request: call => native.sqlite(JSON.stringify(call)),
  get defaultDirectory() {
    return native.dataDirectory;
  },
  subscribe(listener: (event: DatabaseChangeEvent) => void) {
    const controller = new AbortController();
    void (async () => {
      try {
        for await (const event of stream<DatabaseChangeEvent>("sqlite.changes", [], controller.signal, "all")) {
          listener(event);
        }
      } catch (error) {
        if ((error as Error).name !== "AbortError" && !controller.signal.aborted) {
          console.error("watching the databases failed", error);
        }
      }
    })();
    return () => controller.abort(new DOMException("the listener was removed", "AbortError"));
  },
}).exports;
