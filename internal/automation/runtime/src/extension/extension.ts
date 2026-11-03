import type * as swiplet from "@swipt/api/swiplet";

import { chunk } from "./chunks";
import { createDialog } from "./dialog";
import { DOMException, failureOf } from "./errors";
import { AbortController } from "./events";
import { assets, cacheDirectory, dataDirectory } from "./files";
import {
  getCalendars,
  getLocales,
  preferredLocalizations,
} from "./localization";
import { native } from "./native";
import { installLocalStorage, sqlite, sqliteStore } from "./sqlite";

type Caller = swiplet.ActionCaller;
const exposable: readonly Caller[] = ["shortcuts"];

interface StandardSchema {
  "~standard": {
    validate(value: unknown):
      | {
          value?: unknown;
          issues?: readonly {
            message: string;
            path?: readonly (PropertyKey | { key: PropertyKey })[];
          }[];
        }
      | Promise<{
          value?: unknown;
          issues?: readonly {
            message: string;
            path?: readonly (PropertyKey | { key: PropertyKey })[];
          }[];
        }>;
  };
}

interface ActionDefinition {
  title: string;
  description?: string;
  input?: StandardSchema;
  output?: StandardSchema;
  expose?: readonly Caller[];
  run(input: unknown, context: swiplet.ActionContext): unknown;
}

interface ExtensionDefinition {
  run?(context: swiplet.RunContext): Promise<void>;
  actions?: Record<string, object>;
}

interface Action {
  readonly input?: StandardSchema;
  readonly output?: StandardSchema;
  run(input: unknown, context: swiplet.ActionContext): unknown;
}

interface Extension {
  run?(context: swiplet.RunContext): Promise<void>;
  actions: Record<string, Action>;
}

const definitions = new WeakMap<object, Extension>();
const actionDefinitions = new WeakMap<object, Action>();

const schemaOf = (value: unknown, name: string): StandardSchema | undefined => {
  if (value === undefined) {
    return undefined;
  }
  if (
    value === null ||
    typeof value !== "object" ||
    typeof (value as StandardSchema)["~standard"]?.validate !== "function"
  ) {
    throw new TypeError(`${name} is not a Standard Schema`);
  }
  return value as StandardSchema;
};

export const defineAction: typeof swiplet.defineAction = (
  definition: ActionDefinition,
) => {
  if (definition === null || typeof definition !== "object") {
    throw new TypeError("the action definition must be an object");
  }
  const { title, description, expose = [], run } = definition;
  if (typeof title !== "string" || title === "") {
    throw new TypeError("an action needs a title");
  }
  if (description !== undefined && typeof description !== "string") {
    throw new TypeError("the description must be a string");
  }
  if (
    !Array.isArray(expose) ||
    !expose.every((caller) => exposable.includes(caller))
  ) {
    throw new TypeError(`expose must be an array of ${exposable.join(", ")}`);
  }
  if (typeof run !== "function") {
    throw new TypeError("an action needs a run function");
  }
  const out = Object.freeze({
    title,
    description,
    expose: Object.freeze([...expose]),
    run,
    input: schemaOf(definition.input, "the input"),
    output: schemaOf(definition.output, "the output"),
  });
  actionDefinitions.set(out, out);
  return out as never;
};

export const defineExtension: typeof swiplet.defineExtension = (
  definition: ExtensionDefinition,
) => {
  if (definition === null || typeof definition !== "object") {
    throw new TypeError("the extension definition must be an object");
  }
  if (definition.run !== undefined && typeof definition.run !== "function") {
    throw new TypeError("run must be a function");
  }
  const actions = definition.actions ?? {};
  const resolved: Record<string, Action> = {};
  for (const [name, item] of Object.entries(actions)) {
    const action = actionDefinitions.get(item);
    if (action === undefined) {
      throw new TypeError(
        `the action ${JSON.stringify(name)} was not made with defineAction()`,
      );
    }
    resolved[name] = action;
  }
  const out = Object.freeze({ actions: Object.freeze({ ...actions }) });
  definitions.set(out, { run: definition.run, actions: resolved });
  return out as never;
};

interface Modules {
  "@swipt/api": typeof import("@swipt/api");
  "@swipt/api/swiplet": typeof import("@swipt/api/swiplet");
  "@swipt/api/file-system": typeof import("@swipt/api/file-system");
  "@swipt/api/accessibility": typeof import("@swipt/api/accessibility");
  "@swipt/api/input": typeof import("@swipt/api/input");
  "@swipt/api/device": typeof import("@swipt/api/device");
  "@swipt/api/screen": typeof import("@swipt/api/screen");
  "@swipt/api/image": typeof import("@swipt/api/image");
  "expo-localization": typeof import("./types/expo-localization");
  "expo-sqlite": typeof import("./types/expo-sqlite");
  "expo-sqlite/kv-store": typeof import("./types/expo-sqlite/kv-store");
  "expo-sqlite/localStorage/install": typeof import("./types/expo-sqlite/localStorage/install");
}

const interfaceOnly = (name: string) => (): never => {
  throw new Error(`${name} works only in the swiplet interface`);
};

const moduleTable = {
  "@swipt/api": () => ({ __esModule: true }),
  "@swipt/api/swiplet": () => ({
    __esModule: true,
    defineExtension,
    defineAction,
    preferredLocalizations,
    actions: interfaceOnly("actions"),
    useService: interfaceOnly("useService"),
    exit: interfaceOnly("exit"),
  }),
  "@swipt/api/file-system": () => ({
    __esModule: true,
    get dataDirectory() {
      return dataDirectory();
    },
    get cacheDirectory() {
      return cacheDirectory();
    },
    get assets() {
      return assets();
    },
  }),
  "@swipt/api/accessibility": () => ({
    __esModule: true,
    ...chunk("api").accessibility,
  }),
  "@swipt/api/input": () => ({ __esModule: true, ...chunk("api").input }),
  "@swipt/api/device": () => ({ __esModule: true, ...chunk("api").device }),
  "@swipt/api/screen": () => ({ __esModule: true, ...chunk("api").screen }),
  "@swipt/api/image": () => ({ __esModule: true, ...chunk("api").image }),
  "expo-localization": () => ({ __esModule: true, getLocales, getCalendars }),
  "expo-sqlite": sqlite,
  "expo-sqlite/kv-store": sqliteStore,
  "expo-sqlite/localStorage/install": installLocalStorage,
} satisfies { [Specifier in keyof Modules]: () => Modules[Specifier] };

type Declared<Undeclared extends never> = Undeclared;
type UndeclaredExports = Declared<
  {
    [Specifier in keyof Modules]: Exclude<
      keyof ReturnType<(typeof moduleTable)[Specifier]>,
      keyof Modules[Specifier] | "__esModule"
    >;
  }[keyof Modules]
>;

export const modules: Record<string, () => object> = moduleTable;

const require = (specifier: string): object => {
  const module = modules[specifier];
  if (module === undefined) {
    throw new Error(
      `Swipt doesn't provide "${specifier}" to extensions; bundle it into extension.js`,
    );
  }
  return module();
};

const issuesOf = (
  where: string,
  issues: readonly {
    message: string;
    path?: readonly (PropertyKey | { key: PropertyKey })[];
  }[],
) =>
  new TypeError(
    `the ${where} does not match its schema: ${issues
      .map((issue) => {
        const path = (issue.path ?? [])
          .map((segment) =>
            typeof segment === "object" ? String(segment.key) : String(segment),
          )
          .join(".");
        return path === "" ? issue.message : `${path}: ${issue.message}`;
      })
      .join("; ")}`,
  );

const validate = async (
  schema: StandardSchema | undefined,
  value: unknown,
  where: string,
) => {
  if (schema === undefined) {
    return value;
  }
  const result = await schema["~standard"].validate(value);
  if (result.issues) {
    throw issuesOf(where, result.issues);
  }
  return result.value;
};

let loaded: Extension | undefined;
const controller = new AbortController();
const dialog = createDialog();

const serialize = (value: unknown): string => {
  let json: string | undefined;
  try {
    json = value === undefined ? "null" : JSON.stringify(value);
  } catch (error) {
    throw new TypeError(
      `the output does not pass through JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  if (json === undefined) {
    throw new TypeError("the output does not pass through JSON");
  }
  return json;
};

const settle = (work: () => unknown) => {
  Promise.resolve()
    .then(work)
    .then(serialize)
    .then(
      (json) => native.finish("", json),
      (error) =>
        native.finish(
          failureOf(
            controller.signal.aborted && error === controller.signal.reason
              ? new DOMException("the execution was aborted", "AbortError")
              : error,
          ),
          "",
        ),
    );
};

export const hooks = {
  load(
    factory: (
      require: (specifier: string) => object,
      module: { exports: Record<string, unknown> },
      exports: Record<string, unknown>,
    ) => void,
  ): void {
    const module: { exports: Record<string, unknown> } = { exports: {} };
    factory(require, module, module.exports);
    const exported = (module.exports.default ?? module.exports) as object;
    loaded = definitions.get(exported);
    if (loaded === undefined) {
      throw new TypeError(
        "extension.js must export the result of defineExtension as its default export",
      );
    }
  },
  start(): void {
    const run = loaded?.run;
    if (run === undefined) {
      native.finish(
        JSON.stringify({
          name: "NotSupportedError",
          message: "the extension has no run function",
        }),
        "",
      );
      return;
    }
    settle(async () => {
      await run({ signal: controller.signal, dialog });
    });
  },
  call(name: string, input: string, caller: Caller): void {
    const definition = Object.hasOwn(loaded?.actions ?? {}, name)
      ? loaded!.actions[name]
      : undefined;
    if (definition === undefined) {
      native.finish(
        JSON.stringify({
          name: "NotFoundError",
          message: `the extension has no action ${JSON.stringify(name)}`,
        }),
        "",
      );
      return;
    }
    const context = Object.freeze({
      signal: controller.signal,
      caller,
      dialog,
    });
    settle(async () => {
      const value = await validate(
        definition.input,
        JSON.parse(input),
        "input",
      );
      const output = await definition.run(
        definition.input === undefined && value === null ? undefined : value,
        context,
      );
      return validate(definition.output, output, "output");
    });
  },
  abort(): void {
    controller.abort();
  },
};
