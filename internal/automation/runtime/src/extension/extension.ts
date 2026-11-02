import { accessibility, device, image, input, screen } from "./api";
import { createDialog, type Dialog } from "./dialog";
import { DOMException, failureOf } from "./errors";
import { AbortController } from "./events";
import { assets, dataDirectory } from "./files";
import { getCalendars, getLocales, preferredLocalizations } from "./localization";
import { native } from "./native";
import { sqlite } from "./sqlite";

type Caller = "app" | "shortcuts" | "api";
const exposable: Caller[] = ["shortcuts"];

interface StandardSchema {
  "~standard": {
    validate(value: unknown): { value?: unknown; issues?: readonly { message: string; path?: readonly (PropertyKey | { key: PropertyKey })[] }[] } | Promise<{ value?: unknown; issues?: readonly { message: string; path?: readonly (PropertyKey | { key: PropertyKey })[] }[] }>;
  };
}

interface ActionDefinition {
  title: string;
  description?: string;
  input?: StandardSchema;
  output?: StandardSchema;
  expose?: Caller[];
  run(input: unknown, context: { signal: AbortSignal; caller: Caller; dialog: Dialog }): unknown;
}

interface ExtensionDefinition {
  run?(context: { signal: AbortSignal; dialog: Dialog }): Promise<void>;
  actions?: Record<string, ActionDefinition>;
}

const definitions = new WeakMap<object, ExtensionDefinition>();
const actionDefinitions = new WeakSet<object>();

const schemaOf = (value: unknown, name: string): StandardSchema | undefined => {
  if (value === undefined) {
    return undefined;
  }
  if (value === null || typeof value !== "object" || typeof (value as StandardSchema)["~standard"]?.validate !== "function") {
    throw new TypeError(`${name} is not a Standard Schema`);
  }
  return value as StandardSchema;
};

export function defineAction(definition: ActionDefinition) {
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
  if (!Array.isArray(expose) || !expose.every(caller => exposable.includes(caller))) {
    throw new TypeError(`expose must be an array of ${exposable.join(", ")}`);
  }
  if (typeof run !== "function") {
    throw new TypeError("an action needs a run function");
  }
  const out = Object.freeze({
    title, description, expose: Object.freeze([...expose]), run,
    input: schemaOf(definition.input, "the input"), output: schemaOf(definition.output, "the output"),
  });
  actionDefinitions.add(out);
  return out;
}

export function defineExtension(definition: ExtensionDefinition) {
  if (definition === null || typeof definition !== "object") {
    throw new TypeError("the extension definition must be an object");
  }
  if (definition.run !== undefined && typeof definition.run !== "function") {
    throw new TypeError("run must be a function");
  }
  const actions = definition.actions ?? {};
  for (const [name, item] of Object.entries(actions)) {
    if (!actionDefinitions.has(item)) {
      throw new TypeError(`the action ${JSON.stringify(name)} was not made with defineAction()`);
    }
  }
  const out = Object.freeze({ actions: Object.freeze({ ...actions }) });
  definitions.set(out, { run: definition.run, actions });
  return out;
}

const modules: Record<string, () => object> = {
  "@swipt/api": () => ({ __esModule: true }),
  "@swipt/api/swiplet": () => ({ __esModule: true, defineExtension, defineAction, preferredLocalizations }),
  "@swipt/api/file-system": () => ({
    __esModule: true,
    get dataDirectory() {
      return dataDirectory();
    },
    get assets() {
      return assets();
    },
  }),
  "@swipt/api/accessibility": () => ({ __esModule: true, ...accessibility }),
  "@swipt/api/input": () => ({ __esModule: true, ...input }),
  "@swipt/api/device": () => ({ __esModule: true, ...device }),
  "@swipt/api/screen": () => ({ __esModule: true, ...screen }),
  "@swipt/api/image": () => ({ __esModule: true, ...image }),
  "expo-localization": () => ({ __esModule: true, getLocales, getCalendars }),
  "expo-sqlite": sqlite,
};

const require = (specifier: string): object => {
  const module = modules[specifier];
  if (module === undefined) {
    throw new Error(`Swipt doesn't provide "${specifier}" to extensions; bundle it into extension.js`);
  }
  return module();
};

const issuesOf = (where: string, issues: readonly { message: string; path?: readonly (PropertyKey | { key: PropertyKey })[] }[]) =>
  new TypeError(`the ${where} does not match its schema: ${issues.map(issue => {
    const path = (issue.path ?? []).map(segment => typeof segment === "object" ? String(segment.key) : String(segment)).join(".");
    return path === "" ? issue.message : `${path}: ${issue.message}`;
  }).join("; ")}`);

const validate = async (schema: StandardSchema | undefined, value: unknown, where: string) => {
  if (schema === undefined) {
    return value;
  }
  const result = await schema["~standard"].validate(value);
  if (result.issues) {
    throw issuesOf(where, result.issues);
  }
  return result.value;
};

let loaded: ExtensionDefinition | undefined;
const controller = new AbortController();
const dialog = createDialog();

const serialize = (value: unknown): string => {
  let json: string | undefined;
  try {
    json = value === undefined ? "null" : JSON.stringify(value);
  } catch (error) {
    throw new TypeError(`the output does not pass through JSON: ${error instanceof Error ? error.message : String(error)}`);
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
    .then(json => native.finish("", json), error => native.finish(failureOf(controller.signal.aborted && error === controller.signal.reason ? new DOMException("the execution was aborted", "AbortError") : error), ""));
};

export const hooks = {
  load(factory: (require: (specifier: string) => object, module: { exports: Record<string, unknown> }, exports: Record<string, unknown>) => void): void {
    const module: { exports: Record<string, unknown> } = { exports: {} };
    factory(require, module, module.exports);
    const exported = (module.exports.default ?? module.exports) as object;
    loaded = definitions.get(exported);
    if (loaded === undefined) {
      throw new TypeError("extension.js must export the result of defineExtension as its default export");
    }
  },
  start(): void {
    const run = loaded?.run;
    if (run === undefined) {
      native.finish(JSON.stringify({ name: "NotSupportedError", message: "the extension has no run function" }), "");
      return;
    }
    settle(async () => {
      await run({ signal: controller.signal, dialog });
    });
  },
  call(name: string, input: string, caller: Caller): void {
    const definition = Object.hasOwn(loaded?.actions ?? {}, name) ? loaded!.actions![name] : undefined;
    if (definition === undefined) {
      native.finish(JSON.stringify({ name: "NotFoundError", message: `the extension has no action ${JSON.stringify(name)}` }), "");
      return;
    }
    const context = Object.freeze({ signal: controller.signal, caller, dialog });
    settle(async () => {
      const value = await validate(definition.input, JSON.parse(input), "input");
      const output = await definition.run(definition.input === undefined && value === null ? undefined : value, context);
      return validate(definition.output, output, "output");
    });
  },
  abort(): void {
    controller.abort();
  },
};
