import { inspect } from "../shared/inspect";
import { replHead } from "./head";
import { native } from "./native";

export interface Frame {
  function: string;
  file: string;
  line: number;
  column: number;
}

const keptInputs = 256;
const inputColumns = new Map<string, [output: number, input: number][][]>();

export const setInputColumns = (id: string, columns: [output: number, input: number][][]): void => {
  inputColumns.set(id, columns);
  if (inputColumns.size > keptInputs) {
    inputColumns.delete(inputColumns.keys().next().value!);
  }
};

const frame = (name: string, url: string, line: number, column: number): Frame | undefined => {
  let file = url;
  if (url === "extension.js") {
    column = line === 1 ? column - native.extensionHead.length : column;
  } else if (/^input-\d+\.js$/.test(url)) {
    file = "input.js";
    const anchors = inputColumns.get(url.slice("input-".length, -".js".length))?.[line - 1] ?? [[line === 1 ? replHead.length + 1 : 1, 1]];
    const [output, input] = anchors.findLast(([start]) => start <= column) ?? anchors[0];
    column = input + column - output;
  } else {
    return undefined;
  }
  return { function: name === "global code" ? "" : name, file, line, column: Math.max(column, 1) };
};

export const framesOf = (error: Error & { line?: number; column?: number; sourceURL?: string }): Frame[] => {
  const frames: Frame[] = [];
  for (const text of String(error.stack ?? "").split("\n")) {
    const match = /^(.*?)@(.+):(\d+):(\d+)$/.exec(text);
    const found = match && frame(match[1], match[2], Number(match[3]), Number(match[4]));
    if (found) {
      frames.push(found);
    }
  }
  if (frames.length === 0 && error.sourceURL !== undefined && (error.line ?? 0) > 0) {
    const found = frame("", error.sourceURL, error.line!, error.column ?? 1);
    if (found) {
      frames.push(found);
    }
  }
  return frames;
};

const where = (frame: Frame): string => {
  const position = `${frame.file}:${frame.line}:${frame.column}`;
  return frame.function === "" ? position : `${frame.function} (${position})`;
};

export const describe = (error: unknown): string => {
  if (!(error instanceof Error)) {
    return `Uncaught ${inspect(error)}`;
  }
  return `${error.name}: ${error.message}${framesOf(error).map(item => `\n    at ${where(item)}`).join("")}`;
};

export const format = (value: unknown): string => {
  if (typeof value === "string") {
    return value;
  }
  if (value instanceof Error) {
    return describe(value);
  }
  return inspect(value);
};

export const formatAll = (...values: unknown[]): string => values.map(format).join(" ");

export const jsonOf = (value: unknown): string => {
  try {
    return JSON.stringify(value, (_key, item: unknown) => {
      if (typeof item === "bigint") {
        return String(item);
      }
      if (item instanceof Map) {
        return Object.fromEntries(Array.from(item, ([key, entry]) => [typeof key === "string" ? key : inspect(key), entry]));
      }
      if (item instanceof Set) {
        return Array.from(item);
      }
      if (item instanceof Error) {
        return { name: item.name, message: item.message };
      }
      if (item instanceof ArrayBuffer) {
        return Array.from(new Uint8Array(item));
      }
      if (item instanceof DataView) {
        return Array.from(new Uint8Array(item.buffer, item.byteOffset, item.byteLength));
      }
      if (ArrayBuffer.isView(item)) {
        return Array.from(item as unknown as ArrayLike<unknown>);
      }
      return item;
    }) ?? "null";
  } catch {
    return "null";
  }
};
