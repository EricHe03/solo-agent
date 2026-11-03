import { modules } from "swipt:modules";
import { native } from "./native";

export interface Chunks {
  "encoding-tables": typeof import("../shared/encoding-tables");
  sqlite: typeof import("../shared/sqlite");
  subtle: typeof import("./subtle");
  api: typeof import("./api");
  url: typeof import("./whatwg-url");
}

const loaded = new Map<keyof Chunks, unknown>();

export const chunk = <Name extends keyof Chunks>(name: Name): Chunks[Name] => {
  if (!loaded.has(name)) {
    loaded.set(name, native.chunk(name)(modules));
  }
  return loaded.get(name) as Chunks[Name];
};
