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
