#!/usr/bin/env node
import path from "node:path";
import { parseArgs } from "node:util";

import { Code, RpcError, UsageError } from "./client.mjs";
import * as device from "./device.mjs";
import { FalseResult } from "./output.mjs";
import { buildProject, createCommand, sourceCommand } from "./project.mjs";
import { sources } from "./sourcemap.mjs";

const globalOptions = {
  host: { type: "string", value: "URL", help: "Swipt URL (SWIPT_HOST)" },
  token: { type: "string", value: "TOKEN", help: "API token (SWIPT_TOKEN)" },
  timeout: { type: "string", value: "DURATION", help: "time limit" },
  help: { type: "boolean", short: "h", help: "help" },
};

const projectOption = { project: { type: "string", value: "DIRECTORY", help: "swiplet project for source maps" } };

const durationUnits = { ns: 1e-6, us: 1e-3, "µs": 1e-3, ms: 1, s: 1000, m: 60_000, h: 3_600_000 };

function parseDuration(text, option) {
  if (text === undefined) {
    return 0;
  }
  if (/^-?\d+$/.test(text) && Number(text) === 0) {
    return 0;
  }
  let total = 0;
  let rest = text;
  while (rest !== "") {
    const match = /^(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|ms|s|m|h)/.exec(rest);
    if (!match) {
      throw new UsageError(`invalid argument ${JSON.stringify(text)} for ${option}: it is a duration such as 30s or 1m30s`);
    }
    total += Number(match[1]) * durationUnits[match[2]];
    rest = rest.slice(match[0].length);
  }
  return total;
}

function parseCount(text, option) {
  if (text === undefined) {
    return undefined;
  }
  if (!/^\d+$/.test(text) || Number(text) > 0xffffffff) {
    throw new UsageError(`invalid argument ${JSON.stringify(text)} for ${option}: it is a number`);
  }
  return Number(text);
}

const commands = [
  {
    name: "create",
    use: "create DIRECTORY",
    short: "Make a swiplet project in a new or empty directory",
    args: [1, 1],
    run: ({ args }) => createCommand(args[0]),
  },
  {
    name: "build",
    short: "Bundle the project in this directory into dist/<swiplet.id>.swiplet",
    args: [0, 0],
    run: async () => {
      const { archive } = await buildProject(process.cwd());
      console.log(path.relative(process.cwd(), archive));
    },
  },
  {
    name: "source",
    use: "source [SWIPLET...]",
    short: 'Gather the built swiplets of this directory\'s workspaces, or the given ones, into dist/ with a swiplets.json described by "source" in package.json',
    args: [0, Infinity],
    run: ({ args }) => sourceCommand(process.cwd(), args),
  },
  { name: "devices", short: "List the devices that publish Swipt on the local network", args: [0, 0], run: device.devices },
  { name: "info", short: "Show the device and its connection", args: [0, 0], run: device.info },
  { name: "version", short: "Print the version", args: [0, 0], run: device.printVersion },
  { name: "swiplets", use: "swiplets [ID]", short: "List the swiplets or show one", args: [0, 1], options: projectOption, run: device.swiplets },
  {
    name: "call",
    use: "call ID ACTION",
    short: "Call a swiplet action",
    args: [2, 2],
    options: { input: { type: "string", value: "JSON", help: "input JSON, @FILE or -" }, ...projectOption },
    run: device.call,
  },
  {
    name: "service",
    short: "Manage swiplet services",
    options: projectOption,
    commands: [
      { name: "enable", use: "enable ID", short: "Turn on a swiplet service", args: [1, 1], options: { watch: { type: "boolean", help: "watch the state" } }, run: device.setService(true) },
      { name: "disable", use: "disable ID", short: "Turn off a swiplet service", args: [1, 1], options: { watch: { type: "boolean", help: "watch the state" } }, run: device.setService(false) },
      { name: "watch", use: "watch [ID]", short: "Watch swiplet services", args: [0, 1], run: device.serviceWatch },
    ],
  },
  { name: "remove", use: "remove ID", short: "Remove a swiplet", args: [1, 1], run: device.remove },
  {
    name: "files",
    short: "Manage swiplet data files",
    commands: [
      { name: "list", use: "list ID [PATH]", short: "List data files", args: [1, 2], options: { recursive: { type: "boolean", help: "include subdirectories" } }, run: device.filesList },
      { name: "read", use: "read ID PATH", short: "Read a data file or directory", args: [2, 2], options: { output: { type: "string", value: "PATH", help: "destination" } }, run: device.filesRead },
      { name: "write", use: "write ID PATH [FILE | -]", short: "Write a data file", args: [2, 3], run: device.filesWrite },
      { name: "remove", use: "remove ID PATH", short: "Remove a data file", args: [2, 2], options: { recursive: { type: "boolean", help: "include directory contents" } }, run: device.filesRemove },
    ],
  },
  { name: "deploy", use: "deploy [ARCHIVE | PROJECT]", short: "Build and install a swiplet", args: [0, 1], run: device.deployCommand },
  {
    name: "develop",
    use: "develop [PROJECT]",
    short: "Build, install and follow a swiplet project as it changes",
    args: [0, 1],
    options: { "no-logs": { type: "boolean", help: "without logs" } },
    run: device.develop,
  },
  {
    name: "logs",
    short: "Print the logs",
    args: [0, 0],
    options: {
      follow: { type: "boolean", help: "follow new entries" },
      tail: { type: "string", value: "COUNT", help: "number of past entries (default 100)" },
      since: { type: "string", value: "DURATION", help: "maximum age" },
      level: { type: "string", value: "LEVEL", help: "minimum level (default info)" },
      swiplet: { type: "string", value: "ID", help: "swiplet ID" },
    },
    parse: options => ({ ...options, tail: parseCount(options.tail, "--tail"), since: parseDuration(options.since, "--since"), level: options.level ?? "info" }),
    run: device.logs,
  },
  {
    name: "js",
    use: "js [CODE | -]",
    short: "Run JavaScript on the device",
    args: [0, 1],
    options: {
      file: { type: "string", value: "FILE", help: "script file" },
      reset: { type: "boolean", help: "reset the session first" },
      api: { type: "boolean", help: "TypeScript declarations" },
      output: { type: "string", value: "DIRECTORY", help: "image directory" },
    },
    run: device.js,
  },
];

const root = { name: "swipt", short: "Operate a device through Swipt", commands };

const parseOptions = options => Object.fromEntries(Object.entries(options ?? {}).map(([name, option]) => [name, { type: option.type, ...(option.short ? { short: option.short } : {}) }]));

function allOptions(command, collected = {}) {
  Object.assign(collected, parseOptions(command.options));
  for (const child of command.commands ?? []) {
    allOptions(child, collected);
  }
  return collected;
}

function usage(trail) {
  const command = trail.at(-1);
  const name = trail.map(it => it.name).join(" ");
  const lines = [command.short, ""];
  if (command.commands) {
    lines.push(`usage: ${name} COMMAND`, "", "commands:");
    lines.push(...columns(command.commands.map(child => [`  ${child.use ?? child.name}`, child.short])).split("\n"));
  } else {
    lines.push(`usage: ${trail.slice(0, -1).map(it => it.name).join(" ")} ${command.use ?? command.name}`.replace(/ +/g, " "));
  }
  const options = { ...trail.reduce((found, it) => ({ ...found, ...it.options }), {}), ...globalOptions };
  lines.push("", "options:");
  lines.push(...columns(Object.entries(options).map(([option, it]) => [`  --${option}${it.value ? ` ${it.value}` : ""}`, it.help])).split("\n"));
  return lines.join("\n");
}

function columns(rows) {
  const width = Math.max(...rows.map(row => row[0].length));
  return rows.map(row => `${row[0].padEnd(width + 2)}${row[1]}`).join("\n");
}

function resolve(argv) {
  const loose = parseArgs({ args: argv, options: { ...parseOptions(globalOptions), ...allOptions(root) }, allowPositionals: true, strict: false });
  const trail = [root];
  let consumed = 0;
  let help = loose.positionals[0] === "help";
  if (help) {
    consumed++;
  }
  while (trail.at(-1).commands) {
    const current = trail.at(-1);
    const word = loose.positionals[consumed];
    if (word === undefined) {
      if (help || current !== root || argv.length === 0) {
        return { trail, help: true };
      }
      throw new UsageError("a command is missing");
    }
    const found = current.commands.find(it => it.name === word);
    if (!found) {
      throw new UsageError(`unknown command ${JSON.stringify(word)} for ${JSON.stringify(trail.map(it => it.name).join(" "))}`);
    }
    trail.push(found);
    consumed++;
  }
  const options = trail.reduce((found, it) => ({ ...found, ...it.options }), {});
  let parsed;
  try {
    parsed = parseArgs({ args: argv, options: { ...parseOptions(globalOptions), ...parseOptions(options) }, allowPositionals: true, strict: true });
  } catch (error) {
    throw new UsageError(error.message);
  }
  if (parsed.values.help) {
    help = true;
  }
  const args = parsed.positionals.slice(consumed);
  const command = trail.at(-1);
  if (!help && (args.length < command.args[0] || args.length > command.args[1])) {
    const [least, most] = command.args;
    const expected = least === most ? `${least} arg(s)` : most === Infinity ? `at least ${least} arg(s)` : `between ${least} and ${most} arg(s)`;
    throw new UsageError(`accepts ${expected}, received ${args.length}`);
  }
  return { trail, help, args, values: parsed.values };
}

function printError(error, { host, timeout, timedOut }, operation) {
  let exit = 1;
  let message = error.message;
  if (error instanceof UsageError) {
    exit = 2;
  } else if (timedOut) {
    message = `the command ran past --timeout ${timeout}`;
  } else if (error instanceof RpcError) {
    switch (error.code) {
      case Code.Unavailable:
        exit = 5;
        message = `Swipt at ${host} is unreachable: ${message}`;
        break;
      case Code.Unauthenticated:
        message += "; copy the token from Swipt › Developer";
        break;
      case Code.Unimplemented:
        message = `Swipt at ${host} does not have this command; update Swipt`;
        break;
      case Code.DeadlineExceeded:
        if (timeout) {
          message = `the command ran past --timeout ${timeout}`;
        }
        break;
    }
  }
  console.error("error:", operation === undefined ? message : `${operation}: ${message}`);
  if (exit === 2) {
    console.error('run "swipt help" for usage');
  }
  return exit;
}

async function main() {
  const interrupt = new AbortController();
  const interrupted = () => interrupt.abort();
  process.once("SIGINT", interrupted);
  process.once("SIGTERM", interrupted);
  let timeout;
  const state = { host: "", timeout: undefined, timedOut: false };
  try {
    const resolved = resolve(process.argv.slice(2));
    if (resolved.help) {
      console.log(usage(resolved.trail));
      return;
    }
    const command = resolved.trail.at(-1);
    const values = command.parse ? command.parse(resolved.values) : resolved.values;
    state.host = values.host ?? process.env.SWIPT_HOST ?? "";
    state.timeout = values.timeout;
    const timeoutMs = parseDuration(values.timeout, "--timeout");
    if (timeoutMs > 0) {
      timeout = AbortSignal.timeout(timeoutMs);
      timeout.addEventListener("abort", () => {
        state.timedOut = true;
      });
    }
    if (values.project !== undefined) {
      sources.root = path.resolve(values.project);
    }
    const globals = { host: values.host ?? "", token: values.token ?? "", timeoutMs };
    const signal = timeout ? AbortSignal.any([interrupt.signal, timeout]) : interrupt.signal;
    await command.run({ args: resolved.args, options: values, globals, signal, interrupt: interrupt.signal, printError: (error, operation) => printError(error, state, operation) });
  } catch (error) {
    if (error instanceof FalseResult) {
      process.exitCode = 1;
    } else if (interrupt.signal.aborted) {
      process.exitCode = 130;
    } else {
      process.exitCode = printError(error, state);
    }
  } finally {
    process.off("SIGINT", interrupted);
    process.off("SIGTERM", interrupted);
  }
}

await main();
