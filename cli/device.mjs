import { createRequire } from "node:module";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import { fromJson, toJson } from "@bufbuild/protobuf";
import { ValueSchema, timestampFromMs } from "@bufbuild/protobuf/wkt";

import { UsageError, unauthenticated } from "./client.mjs";
import { attach } from "./connection.mjs";
import { Ignorer, relativePath } from "./ignore.mjs";
import { columns, dateTime, enumText, printLog, printScriptError, serviceText } from "./output.mjs";
import { buildProject, loadProject } from "./project.mjs";
import { DeviceConnectionProblem, DeviceConnectionProblemSchema, DeviceConnectionStateSchema, LogLevel } from "./proto/common_pb.js";
import { ServiceStatus, ServiceStatusSchema } from "./proto/swiplets_pb.js";
import { sources } from "./sourcemap.mjs";

const uploadChunk = 256 << 10;
const rebuildDelay = 300;
const logReconnect = 2000;

const { version } = createRequire(import.meta.url)("./package.json");

const readStdin = () => fs.readFileSync(0);

const indented = value => JSON.stringify(value, null, 2).replaceAll("\n", "\n  ");

function elapsed(since) {
  const ms = Date.now() - since;
  if (ms < 1000) {
    return `${ms}ms`;
  }
  const seconds = ms / 1000;
  if (seconds < 60) {
    return `${Number(seconds.toFixed(3))}s`;
  }
  return `${Math.floor(seconds / 60)}m${Number((seconds % 60).toFixed(3))}s`;
}

const session = (context, run) => attach(context).then(run);

export function printVersion() {
  console.log("swipt", version, `node ${process.versions.node}`, `${process.platform}/${process.arch}`);
}

export const info = context =>
  session(context, async client => {
    const found = await client.system.getInfo({}, { signal: context.signal });
    const connection = found.deviceConnection;
    let state = enumText(DeviceConnectionStateSchema, connection?.state ?? 0, "DEVICE_CONNECTION_STATE_");
    if (connection && connection.problem !== DeviceConnectionProblem.UNSPECIFIED) {
      state += `, ${enumText(DeviceConnectionProblemSchema, connection.problem, "DEVICE_CONNECTION_PROBLEM_")}`;
    }
    if (connection?.message) {
      state += `: ${connection.message}`;
    }
    console.log(
      columns([
        ["device:", found.deviceName],
        ["udid:", found.udid],
        ["server:", found.serverVersion],
        ["connection:", state],
      ]),
    );
  });

export const logs = context =>
  session(context, async client => {
    const { options } = context;
    const levels = ["error", "warn", "info", "debug"];
    const index = levels.indexOf(options.level);
    if (index < 0) {
      throw new UsageError("--level is error, warn, info or debug");
    }
    const request = { follow: options.follow, tail: options.tail ?? 100, swipletId: options.swiplet ?? "", level: index + 1 };
    if (options.since > 0) {
      request.since = timestampFromMs(Date.now() - options.since);
      if (options.tail === undefined) {
        request.tail = 0xffffffff;
      }
    }
    for await (const response of client.logs.readLogs(request, { signal: context.signal })) {
      printLog(response.entry, true);
    }
  });

function readInput(value) {
  if (value === undefined || value === "") {
    return undefined;
  }
  let data = value;
  try {
    if (value === "-") {
      data = readStdin().toString();
    } else if (value.startsWith("@")) {
      data = fs.readFileSync(value.slice(1), "utf8");
    }
  } catch (error) {
    throw new Error(`read --input: ${error.message}`);
  }
  try {
    return fromJson(ValueSchema, JSON.parse(data));
  } catch (error) {
    throw new UsageError(`--input is not JSON: ${error.message}`);
  }
}

const serviceStatus = state => (state.status === ServiceStatus.UNSPECIFIED ? "stopped" : enumText(ServiceStatusSchema, state.status, "SERVICE_STATUS_"));

const notInstalled = id => new Error(`there is no swiplet ${JSON.stringify(id)}`);

export const swiplets = context =>
  session(context, async client => {
    const { swiplets } = await client.swiplets.listSwiplets({}, { signal: context.signal });
    if (context.args.length === 0) {
      const rows = swiplets.map(swiplet => {
        let service = "";
        let status = "";
        if (swiplet.service) {
          service = swiplet.service.enabled ? "enabled" : "disabled";
          status = serviceStatus(swiplet.service);
          if (swiplet.service.error) {
            status += `: ${swiplet.service.error.name}: ${swiplet.service.error.message}`;
          }
        }
        return [swiplet.id, swiplet.title, swiplet.version, swiplet.actions.map(action => action.name).join(","), service, status];
      });
      console.log(columns([["ID", "TITLE", "VERSION", "ACTIONS", "SERVICE", "STATUS"], ...rows]));
      return;
    }
    const swiplet = swiplets.find(it => it.id === context.args[0]);
    if (!swiplet) {
      throw notInstalled(context.args[0]);
    }
    console.log(swiplet.id, JSON.stringify(swiplet.title), swiplet.version);
    if (swiplet.hasUi) {
      console.log("ui: yes");
    }
    if (swiplet.service) {
      console.log(`service: ${serviceText(swiplet.id, swiplet.service, sources.frame.bind(sources))}`);
    }
    for (const action of swiplet.actions) {
      console.log();
      console.log(`action ${action.name} ${JSON.stringify(action.title)}${action.exposedToShortcuts ? " (shortcuts)" : ""}`);
      if (action.description !== "") {
        console.log(`  ${action.description}`);
      }
      if (action.inputSchema) {
        console.log(`  input: ${indented(action.inputSchema)}`);
      }
      if (action.outputSchema) {
        console.log(`  output: ${indented(action.outputSchema)}`);
      }
    }
  });

export const call = context =>
  session(context, async client => {
    const [id, action] = context.args;
    const input = readInput(context.options.input);
    let result;
    for await (const response of client.swiplets.callAction({ swipletId: id, action, input }, { signal: context.signal })) {
      if (response.part.case === "log") {
        printLog(response.part.value, false);
      } else if (response.part.case === "result") {
        result = response.part.value;
      }
    }
    if (result?.outcome.case === "output") {
      console.log(JSON.stringify(toJson(ValueSchema, result.outcome.value), null, 2));
      return;
    }
    if (result?.outcome.case === "error") {
      throw printScriptError(result.outcome.value, sources.frame(id));
    }
    throw new Error("the server sent no result");
  });

async function watchServices(client, id, signal) {
  for await (const response of client.swiplets.watchServices({ swipletId: id }, { signal })) {
    console.log(`${response.swipletId}: ${serviceText(response.swipletId, response.service, sources.frame.bind(sources))}`);
  }
}

export const setService = enabled => context =>
  session(context, async client => {
    const id = context.args[0];
    const response = await client.swiplets.setServiceEnabled({ swipletId: id, enabled }, { signal: context.signal });
    if (context.options.watch) {
      await watchServices(client, id, context.signal);
      return;
    }
    console.log(`${id}: ${serviceText(id, response.service, sources.frame.bind(sources))}`);
  });

export const serviceWatch = context => session(context, client => watchServices(client, context.args[0] ?? "", context.signal));

export const remove = context =>
  session(context, async client => {
    await client.swiplets.removeSwiplet({ swipletId: context.args[0] }, { signal: context.signal });
    console.log("removed", context.args[0]);
  });

export const filesList = context =>
  session(context, async client => {
    const [id, directory = ""] = context.args;
    const { files } = await client.swiplets.listDataFiles({ swipletId: id, path: directory, recursive: context.options.recursive }, { signal: context.signal });
    const rows = files.map(file => [file.directory ? "-" : String(file.size), dateTime(file.modified), file.directory ? `${file.path}/` : file.path]);
    if (rows.length > 0) {
      console.log(columns(rows));
    }
  });

const isLocal = name => {
  const normalized = path.posix.normalize(name);
  return !path.posix.isAbsolute(normalized) && normalized !== ".." && !normalized.startsWith("../");
};

class FileSink {
  files = new Map();
  saved = 0;

  constructor(root) {
    this.root = root;
  }

  target(name) {
    if (!isLocal(name)) {
      throw new Error(`the server sent the path ${name}, which leaves the output directory`);
    }
    return path.join(this.root, ...name.split("/"));
  }

  begin(name, directory) {
    const target = this.target(name);
    if (directory) {
      fs.mkdirSync(target, { recursive: true });
      return;
    }
    fs.mkdirSync(path.dirname(target), { recursive: true });
    const previous = this.files.get(name);
    if (previous !== undefined) {
      fs.closeSync(previous);
    }
    this.files.set(name, fs.openSync(target, "w"));
    this.saved++;
  }

  write(name, offset, data) {
    const file = this.files.get(name);
    if (file === undefined) {
      throw new Error(`the server sent data for ${name} before announcing it`);
    }
    fs.writeSync(file, data, 0, data.length, Number(offset));
  }

  close() {
    for (const file of this.files.values()) {
      fs.closeSync(file);
    }
  }
}

const printSaved = (target, count) => console.error(`saved ${count} file(s) to ${target}`);

export const filesRead = context =>
  session(context, async client => {
    const [id, given] = context.args;
    const output = context.options.output ?? "";
    const requested = path.posix.normalize(`/${given}`).replace(/^\/+|\/+$/g, "");
    const printing = output === "" || output === "-";
    const directory = () =>
      new UsageError(
        requested === ""
          ? `${JSON.stringify(given)} names the data directory of ${id}; save it with --output DIRECTORY`
          : `${JSON.stringify(requested)} is a directory in the data directory of ${id}; save it with --output DIRECTORY`,
      );
    const relativeTo = name => name.slice(requested.length).replace(/^\//, "");
    let sink;
    let single;
    const contents = [];
    try {
      for await (const response of client.swiplets.readDataFile({ swipletId: id, path: given }, { signal: context.signal })) {
        if (response.part.case === "file") {
          const file = response.part.value;
          if (file.path === requested && !file.directory) {
            single = file;
            continue;
          }
          if (!sink) {
            if (printing) {
              throw directory();
            }
            sink = new FileSink(output);
          }
          sink.begin(relativeTo(file.path), file.directory);
        } else if (response.part.case === "chunk") {
          const chunk = response.part.value;
          if (single && chunk.path === single.path) {
            contents.push(chunk.data);
            continue;
          }
          if (!sink) {
            throw new Error(`the server sent data for ${chunk.path} before announcing it`);
          }
          sink.write(relativeTo(chunk.path), chunk.offset, chunk.data);
        }
      }
    } finally {
      sink?.close();
    }
    if (sink) {
      printSaved(sink.root, sink.saved);
      return;
    }
    if (!single) {
      if (printing) {
        throw directory();
      }
      fs.mkdirSync(output, { recursive: true });
      printSaved(output, 0);
      return;
    }
    const data = Buffer.concat(contents);
    if (printing) {
      process.stdout.write(data);
      return;
    }
    let target = output;
    if (fs.existsSync(target) && fs.statSync(target).isDirectory()) {
      target = path.join(target, path.posix.basename(single.path));
    }
    fs.writeFileSync(target, data);
    printSaved(target, 1);
  });

export const filesWrite = context =>
  session(context, async client => {
    const [id, name, file] = context.args;
    const data = file === undefined || file === "-" ? readStdin() : fs.readFileSync(file);
    await client.swiplets.writeDataFile(
      (async function* () {
        yield { part: { case: "header", value: { swipletId: id, path: name } } };
        for (let offset = 0; offset < data.length; offset += uploadChunk) {
          yield { part: { case: "data", value: data.subarray(offset, offset + uploadChunk) } };
        }
      })(),
      { signal: context.signal },
    );
  });

export const filesRemove = context =>
  session(context, async client => {
    const [id, name] = context.args;
    await client.swiplets.removeDataFile({ swipletId: id, path: name, recursive: context.options.recursive }, { signal: context.signal });
  });

async function deploy(client, archive, signal) {
  const data = fs.readFileSync(archive);
  return client.swiplets.deploySwiplet(
    (async function* () {
      for (let offset = 0; offset < data.length || offset === 0; offset += uploadChunk) {
        yield { chunk: data.subarray(offset, offset + uploadChunk) };
      }
    })(),
    { signal },
  );
}

const printDeployed = (deployed, toStdout) => (toStdout ? console.log : console.error)(deployed.replaced ? "replaced" : "installed", deployed.swiplet.id, deployed.swiplet.version);

export async function deployCommand(context) {
  const [given] = context.args;
  let archive;
  if (given !== undefined && (given.endsWith(".swiplet") || given.endsWith(".zip"))) {
    if (!fs.existsSync(given)) {
      throw new Error(`there is no archive at ${given}`);
    }
    archive = given;
  } else {
    ({ archive } = await buildProject(path.resolve(given ?? ".")));
  }
  await session(context, async client => printDeployed(await deploy(client, archive, context.signal), true));
}

async function follow(signal, fatal, run) {
  while (!signal.aborted) {
    try {
      await run();
    } catch (error) {
      if (unauthenticated(error)) {
        fatal(error);
        return;
      }
    }
    try {
      await sleep(logReconnect, undefined, { signal });
    } catch {
      return;
    }
  }
}

export async function develop(context) {
  const { signal, printError } = context;
  const project = loadProject(path.resolve(context.args[0] ?? "."));
  const root = project.root;
  sources.root = root;
  const client = await attach(context);
  const controller = new AbortController();
  const inner = AbortSignal.any([signal, controller.signal]);
  let fatalReject;
  const fatal = new Promise((_, reject) => {
    fatalReject = reject;
  });
  follow(inner, fatalReject, async () => {
    for await (const response of client.swiplets.watchServices({}, { signal: inner })) {
      if (response.swipletId === project.config.id && response.service?.status === ServiceStatus.FAILED) {
        console.error(`${response.swipletId}: ${serviceText(response.swipletId, response.service, sources.frame.bind(sources))}`);
      }
    }
  });
  if (!context.options["no-logs"]) {
    follow(inner, fatalReject, async () => {
      for await (const response of client.logs.readLogs({ swipletId: project.config.id, follow: true }, { signal: inner })) {
        printLog(response.entry, false);
      }
    });
  }
  let deployed = "";
  const cycle = async () => {
    const started = Date.now();
    let built;
    try {
      built = await buildProject(root);
    } catch (error) {
      if (!inner.aborted) {
        console.error("error:", error.message);
      }
      return;
    }
    sources.forget(built.id);
    if (built.digest === deployed) {
      console.error(`built in ${elapsed(started)}; it came out as deployed, so nothing was deployed`);
      return;
    }
    let result;
    try {
      result = await deploy(client, built.archive, inner);
    } catch (error) {
      if (unauthenticated(error)) {
        throw error;
      }
      if (!inner.aborted) {
        printError(error, "deploy");
      }
      return;
    }
    deployed = built.digest;
    printDeployed(result, false);
    console.error(`built and deployed in ${elapsed(started)}; watching ${root}`);
  };
  const watch = () =>
    new Promise((resolve, reject) => {
      let ignore = new Ignorer(root);
      let timer;
      const watcher = fs.watch(root, { recursive: true }, (_, filename) => {
        if (filename === null) {
          return;
        }
        const name = path.join(root, filename);
        if (path.basename(name) === ".gitignore") {
          ignore = new Ignorer(root);
        }
        let isDirectory = false;
        try {
          isDirectory = fs.statSync(name).isDirectory();
        } catch {
          isDirectory = false;
        }
        const relative = relativePath(root, name);
        if (relative === "" || ignore.ignored(relative, isDirectory)) {
          return;
        }
        clearTimeout(timer);
        timer = setTimeout(() => cycle().catch(reject), rebuildDelay);
      });
      watcher.on("error", error => printError(error, "watch the project"));
      inner.addEventListener(
        "abort",
        () => {
          clearTimeout(timer);
          watcher.close();
          resolve();
        },
        { once: true },
      );
    });
  try {
    await cycle();
    await Promise.race([watch(), fatal]);
  } finally {
    controller.abort();
  }
}

function readScript(args, options) {
  if (args.length === 1 && options.file !== undefined) {
    throw new UsageError("give CODE or --file, not both");
  }
  if (options.file !== undefined) {
    return { code: fs.readFileSync(options.file, "utf8"), run: true };
  }
  if (args.length === 1 && args[0] !== "-") {
    return { code: args[0], run: true };
  }
  if (args.length === 0 && options.reset) {
    return { code: "", run: false };
  }
  return { code: readStdin().toString(), run: true };
}

class ImageSink {
  directory = "";

  constructor(output) {
    this.output = output;
  }

  save(data) {
    if (this.directory === "") {
      if (this.output !== undefined && this.output !== "") {
        this.directory = path.resolve(this.output);
        fs.mkdirSync(this.directory, { recursive: true });
      } else {
        this.directory = fs.mkdtempSync(path.join(os.tmpdir(), "swipt-js-"));
      }
    }
    const name = path.join(this.directory, `image-${crypto.randomBytes(5).toString("hex")}.png`);
    fs.writeFileSync(name, data);
    return name;
  }
}

export async function js(context) {
  const { args, options, signal } = context;
  if (options.api) {
    if (args.length > 0 || options.file !== undefined || options.reset) {
      throw new UsageError("--api takes no script and no --reset");
    }
    await session(context, async client => {
      process.stdout.write((await client.repl.getDeclarations({}, { signal: context.signal })).typescript);
    });
    return;
  }
  const { code, run } = readScript(args, options);
  await session(context, async client => {
    if (options.reset) {
      await client.repl.reset({}, { signal });
    }
    if (!run) {
      return;
    }
    const script = options.file ?? "input.js";
    const images = new ImageSink(options.output);
    let failure;
    for await (const response of client.repl.execute({ code }, { signal })) {
      switch (response.part.case) {
        case "console": {
          const output = response.part.value;
          (output.level === LogLevel.ERROR || output.level === LogLevel.WARN ? console.error : console.log)(output.text);
          break;
        }
        case "value":
          console.log(response.part.value.text);
          break;
        case "image":
          console.log(`[image: ${images.save(response.part.value)}]`);
          break;
        case "error":
          failure = response.part.value;
          break;
      }
    }
    if (failure) {
      throw printScriptError(failure, frame => (frame.file === "input.js" ? { ...frame, file: script } : frame));
    }
  });
}
