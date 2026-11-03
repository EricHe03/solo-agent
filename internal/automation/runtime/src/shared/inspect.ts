type Fields = (value: object) => Iterable<readonly [string, unknown]>;

const views = new Map<object, Fields>();

const getterOf = (
  prototype: object,
  key: string,
): ((this: unknown) => unknown) | undefined => {
  for (
    let current: object | null = prototype;
    current !== null;
    current = Object.getPrototypeOf(current)
  ) {
    const descriptor = Object.getOwnPropertyDescriptor(current, key);
    if (descriptor !== undefined) {
      return descriptor.get;
    }
  }
  return undefined;
};

type Field<T> = (keyof T & string) | readonly [string, (value: T) => unknown];

export function inspectAs<T extends object>(
  type: { prototype: T },
  fields:
    readonly Field<T>[] | ((value: T) => Iterable<readonly [string, unknown]>),
): void {
  if (typeof fields === "function") {
    views.set(type.prototype, fields as Fields);
    return;
  }
  const readers = fields.map(
    (field): readonly [string, (value: object) => unknown] => {
      if (typeof field !== "string") {
        return field as readonly [string, (value: object) => unknown];
      }
      const get = getterOf(type.prototype, field);
      return [
        field,
        (value) => {
          const read =
            get ?? Object.getOwnPropertyDescriptor(value, field)?.get;
          return read === undefined
            ? undefined
            : Reflect.apply(read, value, []);
        },
      ];
    },
  );
  views.set(type.prototype, (value) =>
    readers.map(([key, read]) => [key, read(value)] as const),
  );
}

const viewsOf = (value: object): Fields[] => {
  const found: Fields[] = [];
  for (
    let prototype = Object.getPrototypeOf(value);
    prototype !== null;
    prototype = Object.getPrototypeOf(prototype)
  ) {
    const view = views.get(prototype);
    if (view !== undefined) {
      found.unshift(view);
    }
  }
  return found;
};

const fieldsOf = (
  value: object,
): (readonly [string, unknown])[] | undefined => {
  try {
    return viewsOf(value).flatMap((view) => [...view(value)]);
  } catch {
    return undefined;
  }
};

const custom = (value: object): boolean => {
  const prototype = Object.getPrototypeOf(value);
  return (
    prototype !== null &&
    prototype !== Object.prototype &&
    !Array.isArray(value) &&
    viewsOf(value).length === 0 &&
    typeof (value as { toString?: unknown }).toString === "function" &&
    (value as { toString: unknown }).toString !== Object.prototype.toString
  );
};

const shownItems = 100;

const breakLength = 80;

const identifier = /^[A-Za-z_$][\w$]*$/;

const group = (
  depth: number,
  prefix: string,
  open: string,
  close: string,
  items: string[],
): string => {
  if (items.length === 0) {
    return `${prefix}${open}${close}`;
  }
  const line = `${prefix}${open} ${items.join(", ")} ${close}`;
  if (depth * 2 + line.length <= breakLength && !line.includes("\n")) {
    return line;
  }
  return `${prefix}${open}\n${items.map((item) => `  ${item.replaceAll("\n", "\n  ")}`).join(",\n")}\n${close}`;
};

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
    const items = Array.from(
      { length: Math.min(typed.length, shownItems) },
      (_, index) => inspect(typed[index]),
    );
    if (typed.length > shownItems) {
      items.push(`... ${typed.length - shownItems} more`);
    }
    return group(
      ancestors.length,
      `${typed.constructor.name}(${typed.length}) `,
      "[",
      "]",
      items,
    );
  }
  if (custom(value as object)) {
    return String(value);
  }
  const nested = (item: unknown) => inspect(item, [...ancestors, value]);
  if (Array.isArray(value)) {
    if (
      value.length > 0 &&
      value.every(
        (item) => item !== null && typeof item === "object" && custom(item),
      )
    ) {
      return value.map(String).join("\n");
    }
    return group(ancestors.length, "", "[", "]", Array.from(value, nested));
  }
  if (value instanceof Map) {
    return group(
      ancestors.length,
      `Map(${value.size}) `,
      "{",
      "}",
      Array.from(value, ([key, item]) => `${nested(key)} => ${nested(item)}`),
    );
  }
  if (value instanceof Set) {
    return group(
      ancestors.length,
      `Set(${value.size}) `,
      "{",
      "}",
      Array.from(value, nested),
    );
  }
  const record = value as Record<string, unknown>;
  const prototype = Object.getPrototypeOf(value);
  const fields = fieldsOf(record);
  const own =
    fields === undefined || !views.has(prototype)
      ? Object.keys(record).filter(
          (key) => !fields?.some(([name]) => name === key),
        )
      : [];
  const entries = [
    ...(fields ?? []),
    ...own.map((key) => [key, record[key]] as const),
  ];
  const name =
    prototype &&
    prototype !== Object.prototype &&
    prototype.constructor &&
    prototype.constructor.name;
  return group(
    ancestors.length,
    name ? `${name} ` : "",
    "{",
    "}",
    entries.map(
      ([key, item]) =>
        `${identifier.test(key) ? key : JSON.stringify(key)}: ${nested(item)}`,
    ),
  );
};
