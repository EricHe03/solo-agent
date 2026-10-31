#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { parseArgs } from "node:util";
import vm from "node:vm";

import { build } from "esbuild";

const { version } = JSON.parse(fs.readFileSync(new URL("package.json", import.meta.url), "utf8"));
const { peerDependencies } = createRequire(import.meta.url)("@swipt/api/package.json");

const appModules = [
  "react",
  "react/jsx-runtime",
  "react-native",
  "expo",
  "expo-localization",
  "@expo/ui",
  "@expo/ui/*",
  "@swipt/api",
  "@swipt/api/swiplet",
  "@swipt/api/file-system",
];
const extensionModules = [
  "@swipt/api",
  "@swipt/api/swiplet",
  "@swipt/api/file-system",
  "@swipt/api/accessibility",
  "@swipt/api/input",
  "@swipt/api/device",
  "@swipt/api/screen",
  "@swipt/api/image",
  "expo-localization",
];

const idPattern = /^[a-z0-9][a-z0-9._-]{0,127}$/;

const storedSuffixes = [".webp", ".jxl", ".avif", ".heic", ".heif", ".jpg", ".jpeg", ".png", ".gif", ".mp4", ".mov", ".m4a", ".mp3", ".aac", ".zip", ".gz", ".br", ".zst", ".xz"].join(":");

function loadProject(root) {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const config = manifest.swiplet ?? {};
  if (typeof config.id !== "string" || !idPattern.test(config.id)) {
    throw new Error('"swiplet.id" in package.json must be 1 to 128 lowercase letters, digits, dots, underscores and hyphens starting with a letter or a digit');
  }
  if (typeof config.name !== "string" || config.name === "") {
    throw new Error('"swiplet.name" in package.json must be a non-empty string');
  }
  const localizedNames = config.localizedNames ?? {};
  if (localizedNames === null || typeof localizedNames !== "object" || !Object.values(localizedNames).every(name => typeof name === "string")) {
    throw new Error('"swiplet.localizedNames" in package.json must map languages to names');
  }
  for (const field of ["description", "updateURL"]) {
    if (config[field] !== undefined && typeof config[field] !== "string") {
      throw new Error(`"swiplet.${field}" in package.json must be a string`);
    }
  }
  if (config.versionCode !== undefined && (!Number.isInteger(config.versionCode) || config.versionCode < 1)) {
    throw new Error('"swiplet.versionCode" in package.json must be a positive integer');
  }
  const entry = name => (config[name] === undefined ? undefined : path.resolve(root, config[name]));
  return { root, manifest, config, localizedNames, app: entry("app"), extension: entry("extension") };
}

const typeImport = extension => ({
  name: "swiplet-type-import",
  setup(build) {
    build.onLoad({ filter: /.*/ }, args => {
      if (args.path !== extension) {
        return undefined;
      }
      return { errors: [{ text: `the interface imports ${path.basename(extension)} at run time; import its type with \`import type\`` }] };
    });
  },
});

async function bundle(project) {
  const out = { app: "", extension: "", extensionMap: "" };
  if (project.extension) {
    const result = await build({
      entryPoints: [project.extension],
      outfile: path.join(project.root, "dist", project.config.id, "src", "extension.js"),
      bundle: true,
      format: "cjs",
      platform: "neutral",
      mainFields: ["module", "main"],
      target: "es2022",
      external: extensionModules,
      sourcemap: "external",
      sourcesContent: false,
      write: false,
      logLevel: "silent",
    });
    out.extension = result.outputFiles.find(file => file.path.endsWith(".js")).text;
    out.extensionMap = result.outputFiles.find(file => file.path.endsWith(".map")).text;
  }
  if (project.app) {
    const result = await build({
      entryPoints: [project.app],
      bundle: true,
      format: "cjs",
      platform: "neutral",
      mainFields: ["react-native", "browser", "module", "main"],
      conditions: ["react-native"],
      resolveExtensions: [".ios.tsx", ".ios.ts", ".native.tsx", ".native.ts", ".tsx", ".ts", ".ios.jsx", ".ios.js", ".native.js", ".jsx", ".js", ".json"],
      jsx: "automatic",
      target: "es2020",
      define: { "process.env.NODE_ENV": '"production"', __DEV__: "false" },
      external: appModules,
      write: false,
      logLevel: "silent",
      plugins: project.extension ? [typeImport(project.extension)] : [],
    });
    out.app = result.outputFiles[0].text;
  }
  if (out.app === "" && out.extension === "") {
    throw new Error('package.json names neither "swiplet.app" nor "swiplet.extension"');
  }
  return out;
}

const definitionKey = Symbol("definition");

function describeExtension(source) {
  if (source === "") {
    return { service: false, actions: [] };
  }
  const loading = name => {
    const fail = () => {
      throw new Error(`${name} is used while extension.js loads; use it inside run or an action`);
    };
    const get = (_, key) => (key === "__esModule" ? true : typeof key === "symbol" || key === "then" ? undefined : fail());
    return new Proxy(fail, { get, apply: fail, construct: fail });
  };
  const modules = {
    "@swipt/api": {},
    "@swipt/api/swiplet": {
      defineExtension: definition => ({ [definitionKey]: definition }),
      defineAction: definition => definition,
      actions: loading("actions"),
      useService: loading("useService"),
    },
    "@swipt/api/file-system": {
      get dataDirectory() {
        throw new Error("dataDirectory is used while extension.js loads; use it inside run or an action");
      },
      get assets() {
        throw new Error("assets is used while extension.js loads; use it inside run or an action");
      },
    },
    "@swipt/api/accessibility": loading("accessibility"),
    "@swipt/api/input": loading("input"),
    "@swipt/api/device": loading("device"),
    "@swipt/api/screen": loading("screen"),
    "@swipt/api/image": loading("image"),
    "expo-localization": { getLocales: () => [{ languageTag: "en", languageCode: "en" }], getCalendars: () => [] },
  };
  const ignored = () => 0;
  const context = vm.createContext({
    console, URL, URLSearchParams, TextEncoder, TextDecoder, atob, btoa, structuredClone, queueMicrotask, crypto,
    AbortController, AbortSignal, Event, EventTarget, CustomEvent, DOMException, Headers, Request, Response, Blob,
    fetch: loading("fetch"),
    setTimeout: ignored, setInterval: ignored, clearTimeout: ignored, clearInterval: ignored,
    navigator: { userAgent: "Swipt", language: "en", languages: ["en"] },
  });
  const factory = vm.runInContext(`(function (require, module, exports) {${source}\n})`, context, { filename: "extension.js" });
  const module = { exports: {} };
  factory(
    specifier => {
      if (!Object.hasOwn(modules, specifier)) {
        throw new Error(`Swipt doesn't provide "${specifier}" to extensions; bundle it into extension.js`);
      }
      return modules[specifier];
    },
    module,
    module.exports,
  );
  const definition = (module.exports.default ?? module.exports)?.[definitionKey];
  if (definition === undefined) {
    throw new Error("the extension's default export is not the result of defineExtension");
  }
  const schema = (name, value, side) => {
    if (value === undefined) {
      return undefined;
    }
    const converter = value?.["~standard"]?.jsonSchema;
    if (typeof converter?.[side] !== "function") {
      throw new Error(`the ${side} schema of the action ${JSON.stringify(name)} doesn't implement Standard JSON Schema; use a library that does, such as Zod 4`);
    }
    return converter[side]({ target: "draft-2020-12" });
  };
  const actions = Object.entries(definition.actions ?? {}).map(([name, action]) => {
    if (typeof action?.title !== "string" || action.title === "") {
      throw new Error(`the action ${JSON.stringify(name)} needs a title`);
    }
    const expose = action.expose ?? [];
    if (!Array.isArray(expose) || !expose.every(caller => caller === "shortcuts")) {
      throw new Error(`the action ${JSON.stringify(name)} can only expose itself to "shortcuts"`);
    }
    return {
      name,
      title: action.title,
      ...(action.description ? { description: action.description } : {}),
      ...(expose.length > 0 ? { expose } : {}),
      ...(action.input ? { input: schema(name, action.input, "input") } : {}),
      ...(action.output ? { output: schema(name, action.output, "output") } : {}),
    };
  });
  return { service: typeof definition.run === "function", actions };
}

function swipletManifest(project, output) {
  const { service, actions } = describeExtension(output.extension);
  const { config, localizedNames } = project;
  return {
    id: config.id,
    name: config.name,
    ...(Object.keys(localizedNames).length > 0 ? { localizedNames } : {}),
    ...(config.description ? { description: config.description } : {}),
    ...(project.manifest.version ? { version: project.manifest.version } : {}),
    ...(config.versionCode ? { versionCode: config.versionCode } : {}),
    ...(config.icon ? { icon: config.icon } : {}),
    ...(config.updateURL ? { updateURL: config.updateURL } : {}),
    ...(output.app ? { interface: true } : {}),
    ...(service ? { service } : {}),
    ...(actions.length > 0 ? { actions } : {}),
  };
}

const sourceFiles = output => ({
  ...(output.app ? { "app.js": output.app } : {}),
  ...(output.extension ? { "extension.js": output.extension } : {}),
});

async function buildCommand(root) {
  const project = loadProject(root);
  const output = await bundle(project);
  const manifest = swipletManifest(project, output);
  const dist = path.join(root, "dist");
  const folder = path.join(dist, manifest.id);
  fs.rmSync(folder, { recursive: true, force: true });
  fs.mkdirSync(path.join(folder, "src"), { recursive: true });
  fs.writeFileSync(path.join(folder, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  for (const [file, contents] of Object.entries(sourceFiles(output))) {
    fs.writeFileSync(path.join(folder, "src", file), contents);
  }
  if (output.extensionMap) {
    fs.writeFileSync(path.join(folder, "src", "extension.js.map"), output.extensionMap);
  }
  if (fs.existsSync(path.join(root, "icon.png"))) {
    fs.copyFileSync(path.join(root, "icon.png"), path.join(folder, "icon.png"));
  }
  if (fs.existsSync(path.join(root, "assets"))) {
    fs.cpSync(path.join(root, "assets"), path.join(folder, "assets"), { recursive: true, filter: source => !path.basename(source).startsWith(".") });
  }
  const archive = path.join(dist, `${manifest.id}.swiplet`);
  fs.rmSync(archive, { force: true });
  fs.rmSync(path.join(dist, `${manifest.id}.zip`), { force: true });
  execFileSync("zip", ["-qr", "-n", storedSuffixes, archive, manifest.id, "-x", "*.map"], { cwd: dist });
  console.log(path.relative(process.cwd(), archive));
}

const manifestEntry = /^(?:[^/]+\/)?manifest\.json$/;

function sourceCommand(files, base, output, name) {
  let prefix;
  if (base !== undefined) {
    try {
      prefix = new URL(base.endsWith("/") ? base : `${base}/`);
    } catch {
      throw new UsageError(`--url ${JSON.stringify(base)} is not an absolute URL`);
    }
  }
  const swiplets = new Map();
  for (const file of files) {
    const entry = execFileSync("unzip", ["-Z1", file], { encoding: "utf8" }).split("\n").filter(name => manifestEntry.test(name)).sort((a, b) => a.length - b.length)[0];
    if (entry === undefined) {
      throw new Error(`${file} has no manifest.json`);
    }
    const manifest = JSON.parse(execFileSync("unzip", ["-p", file, entry], { encoding: "utf8" }));
    if (typeof manifest.id !== "string" || !idPattern.test(manifest.id)) {
      throw new Error(`${file} has no valid swiplet id in its manifest`);
    }
    if (swiplets.has(manifest.id)) {
      throw new Error(`${manifest.id} is both ${swiplets.get(manifest.id).file} and ${file}`);
    }
    const data = fs.readFileSync(file);
    swiplets.set(manifest.id, {
      file,
      entry: {
        ...manifest,
        url: prefix ? new URL(path.basename(file), prefix).href : path.basename(file),
        size: data.length,
        sha256: createHash("sha256").update(data).digest("hex"),
      },
    });
  }
  const listed = `${JSON.stringify({ ...(name ? { name } : {}), swiplets: [...swiplets.keys()].sort().map(id => swiplets.get(id).entry) }, null, 2)}\n`;
  if (output) {
    fs.writeFileSync(output, listed);
  } else {
    process.stdout.write(listed);
  }
}

const idOf = name => name.toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^[._-]+/, "").slice(0, 128).replace(/[._-]+$/, "") || "swiplet";

const templates = {
  "package.json": name =>
    `${JSON.stringify(
      {
        name: idOf(name),
        version: "0.1.0",
        private: true,
        swiplet: {
          id: idOf(name),
          name,
          versionCode: 1,
          icon: { color: "blue", symbol: "sparkles" },
          app: "./src/App.tsx",
          extension: "./src/extension.ts",
        },
        scripts: { build: "swiplet build", check: "tsc" },
        dependencies: { zod: "^4.6.7" },
        devDependencies: {
          "@swipt/api": version,
          "@swipt/cli": version,
          typescript: "^7.0.2",
          ...Object.fromEntries(["@expo/ui", "@types/react", "react"].map(name => [name, peerDependencies[name]])),
        },
      },
      null,
      2,
    )}\n`,
  "tsconfig.json": () =>
    `${JSON.stringify(
      {
        compilerOptions: {
          target: "ES2022", module: "ESNext", moduleResolution: "Bundler", jsx: "react-jsx", lib: ["ES2023", "DOM"],
          strict: true, noEmit: true, skipLibCheck: true,
        },
      },
      null,
      2,
    )}\n`,
  ".gitignore": () => "node_modules/\ndist/\n",
  "src/extension.ts": () => `import * as device from "@swipt/api/device";
import { defineAction, defineExtension } from "@swipt/api/swiplet";

export default defineExtension({
  actions: {
    frontApp: defineAction({
      title: "Find the App in Front",
      run: (_, { signal }) => device.foregroundApplication.get({ signal }),
    }),
  },
});
`,
  "src/App.tsx": () => `import { Button, Form, Host, Section, Text } from "@expo/ui/swift-ui";
import { useState } from "react";
import { actions } from "@swipt/api/swiplet";

import type extension from "./extension";

const { frontApp } = actions<typeof extension>();

export default function App() {
  const [app, setApp] = useState("");
  return (
    <Host style={{ flex: 1 }}>
      <Form>
        <Section>
          <Button label="Find the App in Front" onPress={async () => setApp(await frontApp())} />
          {app === "" ? null : <Text>{app}</Text>}
        </Section>
      </Form>
    </Host>
  );
}
`,
};

const quote = value => (/^[\w@%+=:,./-]+$/.test(value) ? value : `'${value.replaceAll("'", "'\\''")}'`);

function createCommand(directory) {
  const root = path.resolve(directory);
  if (fs.existsSync(root) && fs.readdirSync(root).length > 0) {
    throw new Error(`${directory} is not empty`);
  }
  for (const [file, template] of Object.entries(templates)) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), template(path.basename(root)));
  }
  const manager = process.env.npm_config_user_agent?.split("/")[0] ?? "npm";
  console.log(`cd ${quote(directory)} && ${manager} install && ${manager} run build`);
}

const usage = `usage: swiplet create <directory>
       swiplet build
       swiplet source [--name <name>] [--url <address>] [--output <file>] <swiplet>...

  create   make a swiplet project in a new or empty directory
  build    bundle the project in this directory into dist/<swiplet.id>.swiplet
  source   list built swiplets in a source; without --url they are expected next to it

Type-check a project with its "check" script.`;

const commands = { create: 1, build: 0, source: -1 };

class UsageError extends Error {}

try {
  let parsed;
  try {
    parsed = parseArgs({ allowPositionals: true, options: { help: { type: "boolean", short: "h" }, name: { type: "string" }, url: { type: "string" }, output: { type: "string" } } });
  } catch (error) {
    throw new UsageError(error.message);
  }
  const [command, ...rest] = parsed.positionals;
  if (parsed.values.help) {
    console.log(usage);
  } else if (command === undefined) {
    throw new UsageError("a command is missing");
  } else if (!Object.hasOwn(commands, command)) {
    throw new UsageError(`unknown command ${JSON.stringify(command)}`);
  } else if (commands[command] < 0 ? rest.length === 0 : rest.length !== commands[command]) {
    throw new UsageError(
      commands[command] === 0 ? `${command} takes no arguments` : commands[command] < 0 ? `${command} takes one or more swiplets` : `${command} takes one directory`,
    );
  } else if (command === "create") {
    createCommand(rest[0]);
  } else if (command === "source") {
    sourceCommand(rest, parsed.values.url, parsed.values.output, parsed.values.name);
  } else {
    await buildCommand(process.cwd());
  }
} catch (error) {
  if (error instanceof UsageError) {
    console.error(`error: ${error.message}\n\n${usage}`);
    process.exitCode = 2;
  } else {
    console.error(error.message);
    process.exitCode = 1;
  }
}
