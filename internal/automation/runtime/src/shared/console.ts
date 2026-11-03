export type Severity = "info" | "warn" | "error" | "debug";

export interface ConsoleHost {
  print(severity: Severity, text: string): void;
  format(value: unknown): string;
  inspect(value: unknown): string;
  trace(label: string): string;
  now(): number;
}

export interface Console {
  assert(condition?: unknown, ...data: unknown[]): void;
  clear(): void;
  debug(...data: unknown[]): void;
  error(...data: unknown[]): void;
  info(...data: unknown[]): void;
  log(...data: unknown[]): void;
  table(tabularData?: unknown, properties?: Iterable<string>): void;
  trace(...data: unknown[]): void;
  warn(...data: unknown[]): void;
  dir(item?: unknown, options?: unknown): void;
  dirxml(...data: unknown[]): void;
  count(label?: string): void;
  countReset(label?: string): void;
  group(...data: unknown[]): void;
  groupCollapsed(...data: unknown[]): void;
  groupEnd(): void;
  time(label?: string): void;
  timeLog(label?: string, ...data: unknown[]): void;
  timeEnd(label?: string): void;
}

const specifiers = /%[sdifoOc]/g;

const wide = new RegExp(
  "[\\u1100-\\u115f\\u231a\\u231b\\u2329\\u232a\\u23e9-\\u23ec\\u23f0\\u23f3\\u25fd\\u25fe\\u2614\\u2615\\u2648-\\u2653\\u267f\\u2693\\u26a1\\u26aa\\u26ab\\u26bd\\u26be\\u26c4\\u26c5\\u26ce\\u26d4\\u26ea\\u26f2\\u26f3\\u26f5\\u26fa\\u26fd\\u2705\\u270a\\u270b\\u2728\\u274c\\u274e\\u2753-\\u2755\\u2757\\u2795-\\u2797\\u27b0\\u27bf\\u2b1b\\u2b1c\\u2b50\\u2b55\\u2e80-\\u303e\\u3041-\\u33ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\ua000-\\ua4cf\\ua960-\\ua97f\\uac00-\\ud7a3\\uf900-\\ufaff\\ufe10-\\ufe19\\ufe30-\\ufe6f\\uff00-\\uff60\\uffe0-\\uffe6\\u{16fe0}-\\u{1b2ff}\\u{1f004}\\u{1f0cf}\\u{1f18e}\\u{1f191}-\\u{1f19a}\\u{1f200}-\\u{1f251}\\u{1f300}-\\u{1f64f}\\u{1f680}-\\u{1f6ff}\\u{1f7e0}-\\u{1f7eb}\\u{1f90c}-\\u{1f9ff}\\u{1fa70}-\\u{1faff}\\u{20000}-\\u{3fffd}]",
  "u",
);
const zeroWidth = /[\p{Mn}\p{Me}\p{Cf}]/u;

const widthOf = (text: string): number => {
  let width = 0;
  for (const character of text) {
    width += zeroWidth.test(character) ? 0 : wide.test(character) ? 2 : 1;
  }
  return width;
};

const domString = (value: unknown): string => `${value as string}`;
const labelOf = (label: unknown): string =>
  label === undefined ? "default" : domString(label);

const strings = (value: unknown): string[] => {
  if (
    value === null ||
    typeof value !== "object" ||
    typeof (value as Iterable<unknown>)[Symbol.iterator] !== "function"
  ) {
    throw new TypeError("the properties are not a sequence");
  }
  return Array.from(value as Iterable<unknown>, domString);
};

const isObject = (value: unknown): value is object =>
  (typeof value === "object" && value !== null) || typeof value === "function";

const render = (header: string[], rows: string[][]): string => {
  const widths = header.map(
    (name, column) =>
      Math.max(widthOf(name), ...rows.map((row) => widthOf(row[column]))) + 2,
  );
  const line = (left: string, middle: string, right: string) =>
    left + widths.map((width) => "\u2500".repeat(width)).join(middle) + right;
  const row = (cells: string[]) =>
    `\u2502${cells.map((cell, column) => ` ${cell}${" ".repeat(widths[column] - widthOf(cell) - 1)}`).join("\u2502")}\u2502`;
  return [
    line("\u250c", "\u252c", "\u2510"),
    row(header),
    line("\u251c", "\u253c", "\u2524"),
    ...rows.map(row),
    line("\u2514", "\u2534", "\u2518"),
  ].join("\n");
};

export function createConsole(host: ConsoleHost): Console {
  const counts = new Map<string, number>();
  const timers = new Map<string, number>();
  let depth = 0;

  const printer = (severity: Severity, args: readonly unknown[]): void => {
    const text = args.map(host.format).join(" ");
    host.print(
      severity,
      depth === 0 ? text : text.replace(/^/gm, "  ".repeat(depth)),
    );
  };

  const convert = (specifier: string, current: unknown): string => {
    switch (specifier) {
      case "%s":
        try {
          return String(current);
        } catch {
          return host.inspect(current);
        }
      case "%d":
      case "%i":
        try {
          return String(
            typeof current === "symbol" ? NaN : parseInt(current as string, 10),
          );
        } catch {
          return "NaN";
        }
      case "%f":
        try {
          return String(
            typeof current === "symbol" ? NaN : parseFloat(current as string),
          );
        } catch {
          return "NaN";
        }
      case "%o":
      case "%O":
        return host.inspect(current);
    }
    return "";
  };

  const formatter = (args: readonly unknown[]): unknown[] => {
    if (args.length < 2 || typeof args[0] !== "string") {
      return [...args];
    }
    let index = 1;
    const target = args[0].replace(specifiers, (specifier) =>
      index < args.length ? convert(specifier, args[index++]) : specifier,
    );
    return [target, ...args.slice(index)];
  };

  const logger = (severity: Severity, args: readonly unknown[]): void => {
    if (args.length > 0) {
      printer(severity, formatter(args));
    }
  };

  const elapsed = (label: string, method: string): string | undefined => {
    const start = timers.get(label);
    if (start === undefined) {
      printer("warn", [
        `Timer "${label}" does not exist for console.${method}()`,
      ]);
      return undefined;
    }
    return `${label}: ${Number((host.now() - start).toFixed(3))}ms`;
  };

  const group = (method: string, data: readonly unknown[]): void => {
    printer(
      "info",
      data.length === 0 ? [`console.${method}`] : formatter(data),
    );
    depth++;
  };

  const table = (tabularData: unknown, properties?: Iterable<string>): void => {
    const columns = properties === undefined ? undefined : strings(properties);
    if (!isObject(tabularData)) {
      logger("info", [tabularData]);
      return;
    }
    const cell = (value: unknown) =>
      host.inspect(value).replace(/\s*\n\s*/g, " ");
    let index = "(index)";
    let entries: [key: string, value: unknown][];
    const leading: [name: string, values: string[]][] = [];
    if (tabularData instanceof Map) {
      index = "(iteration index)";
      entries = Array.from(tabularData.values(), (value, position) => [
        String(position),
        value,
      ]);
      leading.push(["Key", Array.from(tabularData.keys(), cell)]);
    } else if (tabularData instanceof Set) {
      index = "(iteration index)";
      entries = Array.from(tabularData, (value, position) => [
        String(position),
        value,
      ]);
    } else {
      entries = Object.keys(tabularData).map((key) => [
        key,
        (tabularData as { [key: string]: unknown })[key],
      ]);
    }
    const keys: string[] = columns ?? [];
    let primitives = false;
    for (const [, value] of entries) {
      if (!isObject(value) || typeof value === "function") {
        primitives = true;
      } else if (columns === undefined) {
        for (const key of Object.keys(value)) {
          if (!keys.includes(key)) {
            keys.push(key);
          }
        }
      }
    }
    const header = [
      index,
      ...leading.map(([name]) => name),
      ...keys,
      ...(primitives ? ["Values"] : []),
    ];
    const rows = entries.map(([key, value], position) => {
      const object =
        isObject(value) && typeof value !== "function"
          ? (value as { [key: string]: unknown })
          : undefined;
      return [
        key,
        ...leading.map(([, values]) => values[position]),
        ...keys.map((name) =>
          object !== undefined && Object.hasOwn(object, name)
            ? cell(object[name])
            : "",
        ),
        ...(primitives ? [object === undefined ? cell(value) : ""] : []),
      ];
    });
    printer("info", [render(header, rows)]);
  };

  const console = Object.create(
    Object.create(Object.prototype) as object,
  ) as Console;
  Object.assign(console, {
    assert(condition = false, ...data: unknown[]) {
      if (condition) {
        return;
      }
      if (data.length === 0) {
        data.push("Assertion failed");
      } else if (typeof data[0] !== "string") {
        data.unshift("Assertion failed");
      } else {
        data[0] = `Assertion failed: ${data[0]}`;
      }
      logger("error", data);
    },
    clear() {
      depth = 0;
    },
    debug: (...data: unknown[]) => logger("debug", data),
    error: (...data: unknown[]) => logger("error", data),
    info: (...data: unknown[]) => logger("info", data),
    log: (...data: unknown[]) => logger("info", data),
    table,
    trace(...data: unknown[]) {
      printer("info", [host.trace(formatter(data).map(host.format).join(" "))]);
    },
    warn: (...data: unknown[]) => logger("warn", data),
    dir(item?: unknown) {
      printer("info", [host.inspect(item)]);
    },
    dirxml: (...data: unknown[]) => logger("info", data),
    count(label?: string) {
      const name = labelOf(label);
      const count = (counts.get(name) ?? 0) + 1;
      counts.set(name, count);
      logger("info", [`${name}: ${count}`]);
    },
    countReset(label?: string) {
      const name = labelOf(label);
      if (counts.has(name)) {
        counts.set(name, 0);
      } else {
        printer("warn", [`Count for "${name}" does not exist`]);
      }
    },
    group: (...data: unknown[]) => group("group", data),
    groupCollapsed: (...data: unknown[]) => group("groupCollapsed", data),
    groupEnd() {
      depth = Math.max(depth - 1, 0);
    },
    time(label?: string) {
      const name = labelOf(label);
      if (timers.has(name)) {
        printer("warn", [`Timer "${name}" already exists`]);
      } else {
        timers.set(name, host.now());
      }
    },
    timeLog(label?: string, ...data: unknown[]) {
      const text = elapsed(labelOf(label), "timeLog");
      if (text !== undefined) {
        printer("info", [text, ...data]);
      }
    },
    timeEnd(label?: string) {
      const name = labelOf(label);
      const text = elapsed(name, "timeEnd");
      if (text !== undefined) {
        timers.delete(name);
        printer("info", [text]);
      }
    },
  } satisfies Console);
  Object.defineProperty(console, Symbol.toStringTag, {
    value: "console",
    configurable: true,
  });
  return console;
}
