import type * as SQLite from "../shared/sqlite";
import { invoke, stream } from "./async";
import { chunk } from "./chunks";
import { DOMException } from "./errors";
import { native } from "./native";

let instance: ReturnType<typeof SQLite.createSQLite> | undefined;
let module: Readonly<ReturnType<typeof SQLite.createSQLite>["exports"] & Record<"SQLiteProvider" | "useSQLiteContext", ReturnType<typeof interfaceOnly>>> | undefined;

const created = () => instance ??= chunk("sqlite").createSQLite({
  request: call => native.sqlite(JSON.stringify(call)),
  requestAsync: call => invoke("sqlite", [call]),
  get defaultDirectory() {
    return native.dataDirectory;
  },
  subscribe(listener: (event: SQLite.DatabaseChangeEvent) => void) {
    const controller = new AbortController();
    void (async () => {
      try {
        for await (const events of stream<SQLite.DatabaseChangeEvent[]>("sqlite.changes", [], controller.signal, "all")) {
          for (const event of events) {
            listener(event);
          }
        }
      } catch (error) {
        if ((error as Error).name !== "AbortError" && !controller.signal.aborted) {
          console.error("watching the databases failed", error);
        }
      }
    })();
    return () => controller.abort(new DOMException("the listener was removed", "AbortError"));
  },
});

const interfaceOnly = (name: string) => () => {
  throw new Error(`${name} renders React, so it works only in the swiplet interface`);
};

export const sqlite = () => module ??= Object.freeze({
  ...created().exports,
  SQLiteProvider: interfaceOnly("SQLiteProvider"),
  useSQLiteContext: interfaceOnly("useSQLiteContext"),
});

export const sqliteStore = () => created().kvStore;

export const installLocalStorage = () => {
  Object.defineProperty(globalThis, "localStorage", { value: created().localStorage, configurable: true, enumerable: true, writable: true });
  return { __esModule: true };
};
