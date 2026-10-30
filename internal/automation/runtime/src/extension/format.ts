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

const custom = (value: object): boolean => {
  const prototype = Object.getPrototypeOf(value);
  return prototype !== null && prototype !== Object.prototype && !Array.isArray(value)
    && typeof (value as { toString?: unknown }).toString === "function" && (value as { toString: unknown }).toString !== Object.prototype.toString;
};

const shownItems = 100;

type Typed = ArrayLike<number | bigint> & { constructor: { name: string } };

export const inspect = (value: unknown, ancestors: unknown[] = []): string => {
  switch (typeof value) {
    case "string":
      return JSON.stringify(value);
    case "number":
      return Object.is(value, -0) ? "-0" : String(value);
    case "bigint":
      return `${value}n`;
    case "undefined":
    case "boolean":
    case "symbol":
      return String(value);
    case "function":
      return value.name ? `[Function ${value.name}]` : "[Function]";
  }
  if (value === null) {
    return "null";
  }
  if (ancestors.includes(value)) {
    return "[Circular]";
  }
  if (value instanceof Error) {
    return `${value.name}: ${value.message}`;
  }
  if (value instanceof Date) {
    return Number.isNaN(value.getTime()) ? "Invalid Date" : value.toISOString();
  }
  if (value instanceof RegExp) {
    return String(value);
  }
  if (value instanceof Promise) {
    return "Promise {}";
  }
  if (value instanceof ArrayBuffer) {
    return `ArrayBuffer(${value.byteLength})`;
  }
  if (value instanceof DataView) {
    return `DataView(${value.byteLength})`;
  }
  if (ArrayBuffer.isView(value)) {
    const typed = value as unknown as Typed;
    const items = Array.from({ length: Math.min(typed.length, shownItems) }, (_, index) => inspect(typed[index]));
    if (typed.length > shownItems) {
      items.push(`... ${typed.length - shownItems} more`);
    }
    return `${typed.constructor.name}(${typed.length}) [${items.join(",")}]`;
  }
  if (custom(value as object)) {
    return String(value);
  }
  const nested = (item: unknown) => inspect(item, [...ancestors, value]);
  if (Array.isArray(value)) {
    if (value.length > 0 && value.every(item => item !== null && typeof item === "object" && custom(item))) {
      return value.map(String).join("\n");
    }
    return `[${Array.from(value, nested).join(",")}]`;
  }
  if (value instanceof Map) {
    return `Map(${value.size}) {${Array.from(value, ([key, item]) => `${nested(key)} => ${nested(item)}`).join(", ")}}`;
  }
  if (value instanceof Set) {
    return `Set(${value.size}) {${Array.from(value, nested).join(", ")}}`;
  }
  const record = value as Record<string, unknown>;
  const body = `{${Object.keys(record).map(key => `${JSON.stringify(key)}:${nested(record[key])}`).join(",")}}`;
  const prototype = Object.getPrototypeOf(value);
  const name = prototype && prototype !== Object.prototype && prototype.constructor && prototype.constructor.name;
  return name ? `${name} ${body}` : body;
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
