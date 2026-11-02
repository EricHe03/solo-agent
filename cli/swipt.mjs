#!/usr/bin/env node
import path from "node:path";
import { parseArgs } from "node:util";

import { Code, RpcError, UsageError } from "./client.mjs";
import * as connection from "./connection.mjs";
import * as device from "./device.mjs";
import { FalseResult } from "./output.mjs";
import { buildProject, createCommand, sourceCommand } from "./project.mjs";

const globalOptions = {
  help: { type: "boolean", short: "h", help: "help" },
};

const deviceOption = { device: { type: "string", short: "d", value: "NAME|URL", help: "the device to use (SWIPT_DEVICE)" } };

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

const dataCommands = (operand, files) => {
  const before = operand === "" ? 0 : 1;
  return {
    name: "data",
    short: `Manage the files in the data directory of ${operand === "" ? "the REPL" : "a swiplet"}`,
    commands: [
      { name: "list", use: `list ${operand}[PATH]`, short: "List data files", args: [before, before + 1], options: { recursive: { type: "boolean", help: "include subdirectories" } }, run: files.list },
      { name: "read", use: `read ${operand}PATH`, short: "Read a data file or directory", args: [before + 1, before + 1], options: { output: { type: "string", value: "PATH", help: "destination" } }, run: files.read },
      { name: "write", use: `write ${operand}PATH [FILE | -]`, short: "Write a data file", args: [before + 1, before + 2], run: files.write },
      { name: "remove", use: `remove ${operand}PATH`, short: "Remove a data file", args: [before + 1, before + 1], options: { recursive: { type: "boolean", help: "include directory contents" } }, run: files.remove },
      { name: "clear", use: `clear ${operand}`.trimEnd(), short: "Remove every data file, keeping the data directory", args: [before, before], run: files.clear },
    ],
  };
};

const commands = [
  {
    name: "project",
    short: "Make, build and deploy swiplet projects",
    commands: [
      {
        name: "create",
        use: "create DIRECTORY",
        short: "Make a swiplet project in a new or empty directory",
        args: [1, 1],
        run: ({ args }) => createCommand(args[0]),
      },
      {
        name: "build",
        use: "build [PROJECT]",
        short: "Bundle the project into dist/<swiplet.id>.swiplet",
        args: [0, 1],
        run: async ({ args }) => {
          const { archive } = await buildProject(path.resolve(args[0] ?? "."));
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
      { name: "deploy", use: "deploy [PROJECT]", short: "Build the project and install it on the device", args: [0, 1], options: deviceOption, run: device.deployProject },
      {
        name: "develop",
        use: "develop [PROJECT]",
        short: "Build, install and follow a swiplet project as it changes",
        args: [0, 1],
        options: { ...deviceOption, "no-logs": { type: "boolean", help: "without logs" } },
        run: device.develop,
      },
    ],
  },
  {
    name: "device",
    short: "Manage the devices and read their logs",
    commands: [
      { name: "list", short: "List the devices, adding the ones found on the local network", args: [0, 0], run: connection.list },
      { name: "add", use: "add URL", short: "Add a device by its URL; needed when it is remote or requires a token", args: [1, 1], run: connection.add },
      { name: "remove", use: "remove NAME", short: "Forget a device", args: [1, 1], run: connection.remove },
      {
        name: "logs",
        short: "Print the logs",
        args: [0, 0],
        options: {
          ...deviceOption,
          follow: { type: "boolean", help: "follow new entries" },
          tail: { type: "string", value: "COUNT", help: "number of past entries (default 100)" },
          since: { type: "string", value: "DURATION", help: "maximum age" },
          level: { type: "string", value: "LEVEL", help: "minimum level (default info)" },
          swiplet: { type: "string", value: "ID", help: "swiplet ID" },
        },
        parse: options => ({ ...options, tail: parseCount(options.tail, "--tail"), since: parseDuration(options.since, "--since"), level: options.level ?? "info" }),
        run: device.logs,
      },
    ],
  },
  {
    name: "swiplet",
    short: "Manage the swiplets on the device",
    options: deviceOption,
    commands: [
      { name: "list", short: "List the swiplets", args: [0, 0], run: device.list },
      { name: "show", use: "show ID", short: "Show a swiplet", args: [1, 1], run: device.show },
      { name: "install", use: "install ARCHIVE", short: "Install a swiplet archive", args: [1, 1], run: device.install },
      { name: "remove", use: "remove ID", short: "Remove a swiplet", args: [1, 1], run: device.remove },
      {
        name: "call",
        use: "call ID ACTION",
        short: "Call a swiplet action",
        args: [2, 2],
        options: { input: { type: "string", value: "JSON", help: "input JSON, @FILE or -" } },
        run: device.call,
      },
      {
        name: "service",
        short: "Manage swiplet services",
        commands: [
          { name: "enable", use: "enable ID", short: "Turn on a swiplet service", args: [1, 1], options: { watch: { type: "boolean", help: "watch the state" } }, run: device.setService(true) },
          { name: "disable", use: "disable ID", short: "Turn off a swiplet service", args: [1, 1], options: { watch: { type: "boolean", help: "watch the state" } }, run: device.setService(false) },
          { name: "watch", use: "watch [ID]", short: "Watch swiplet services", args: [0, 1], run: device.serviceWatch },
        ],
      },
      dataCommands("ID ", device.swipletData),
    ],
  },
  {
    name: "repl",
    short: "Run JavaScript in the REPL session on the device",
    options: deviceOption,
    commands: [
      {
        name: "run",
        use: "run [CODE | FILE [ARG...] | - [ARG...]]",
        short: "Run a JavaScript expression or program on the device",
        description: [
          "The first argument is FILE when it names an existing file and CODE otherwise; options go before FILE or -, and every argument after it is an ARG, verbatim.",
          "CODE is an expression; its completion value, awaited if it is a promise, is printed in inspect format: strings quoted, and values with their own toString, which include accessibility snapshots and screen recordings, as that string.",
          "FILE, or standard input given as - or no argument, is a program; only its console output and thrown error are printed, and the global args holds its ARGs.",
          'Top-level await is available, and top-level bindings persist across runs until "swipt repl reset".',
          "An image given to show(), or as the completion value of CODE, is saved as a PNG file and printed as its path.",
          'There is no module system, so import is unavailable; the globals are accessibility, input, device, screen, image, dialog, dataDirectory, show and sleep, declared by "swipt repl api".',
          'dataDirectory is the directory that "swipt repl data" manages.',
        ],
        args: [0, Infinity],
        passthrough: device.isProgram,
        options: { output: { type: "string", value: "DIRECTORY", help: "image directory (default: a new temporary directory)" } },
        run: device.run,
      },
      { name: "reset", short: "Reset the session", args: [0, 0], run: device.reset },
      { name: "api", short: "Print the TypeScript declarations of the globals", args: [0, 0], run: device.api },
      dataCommands("", device.replData),
    ],
  },
  { name: "version", short: "Print the version", args: [0, 0], run: device.printVersion },
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
  if (command.description) {
    lines.push("", ...command.description);
  }
  const options = { ...trail.reduce((found, it) => ({ ...found, ...it.options }), {}), ...globalOptions };
  lines.push("", "options:");
  lines.push(...columns(Object.entries(options).map(([option, it]) => [`  ${it.short ? `-${it.short}, ` : ""}--${option}${it.value ? ` ${it.value}` : ""}`, it.help])).split("\n"));
  return lines.join("\n");
}

function columns(rows) {
  const width = Math.max(...rows.map(row => row[0].length));
  return rows.map(row => `${row[0].padEnd(width + 2)}${row[1]}`).join("\n");
}

function resolve(argv) {
  const loose = parseArgs({ args: argv, options: { ...parseOptions(globalOptions), ...allOptions(root) }, allowPositionals: true, strict: false, tokens: true });
  const positionals = loose.tokens.filter(token => token.kind === "positional");
  const trail = [root];
  let consumed = 0;
  let help = positionals[0]?.value === "help";
  if (help) {
    consumed++;
  }
  while (trail.at(-1).commands) {
    const current = trail.at(-1);
    const word = positionals[consumed]?.value;
    if (word === undefined) {
      if (help || loose.values.help || current !== root || argv.length === 0) {
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
  const command = trail.at(-1);
  const options = trail.reduce((found, it) => ({ ...found, ...it.options }), {});
  const first = positionals[consumed];
  const verbatim = first !== undefined && command.passthrough?.(first.value) ? first.index + 1 : argv.length;
  let parsed;
  try {
    parsed = parseArgs({ args: argv.slice(0, verbatim), options: { ...parseOptions(globalOptions), ...parseOptions(options) }, allowPositionals: true, strict: true });
  } catch (error) {
    const option = error.message.match(/^Unknown option '(-[^']*)'/)?.[1];
    throw new UsageError(option === undefined ? error.message : `${option} is not an option of ${JSON.stringify(trail.map(it => it.name).join(" "))}`);
  }
  if (parsed.values.help) {
    help = true;
  }
  const args = [...parsed.positionals.slice(consumed), ...argv.slice(verbatim)];
  if (!help && (args.length < command.args[0] || args.length > command.args[1])) {
    const [least, most] = command.args;
    const expected = least === most ? `${least} arg(s)` : most === Infinity ? `at least ${least} arg(s)` : `between ${least} and ${most} arg(s)`;
    throw new UsageError(`accepts ${expected}, received ${args.length}`);
  }
  return { trail, help, args, values: parsed.values };
}

function printError(error, target, operation) {
  let exit = 1;
  let message = error.message;
  if (error instanceof UsageError) {
    exit = 2;
  } else if (error instanceof RpcError) {
    switch (error.code) {
      case Code.Unavailable:
        exit = 5;
        message = `Swipt at ${target.url} is unreachable: ${message}`;
        break;
      case Code.Unauthenticated:
        message += `; connect with the URL from Swipt › Developer: swipt device add ${connection.withToken(target.url)}`;
        break;
      case Code.Unimplemented:
        message = `Swipt at ${target.url} does not have this command; update Swipt`;
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
  const target = { url: "" };
  try {
    const resolved = resolve(process.argv.slice(2));
    if (resolved.help) {
      console.log(usage(resolved.trail));
      return;
    }
    const command = resolved.trail.at(-1);
    const values = command.parse ? command.parse(resolved.values) : resolved.values;
    await command.run({ args: resolved.args, options: values, target, signal: interrupt.signal, printError: (error, operation) => printError(error, target, operation) });
  } catch (error) {
    if (error instanceof FalseResult) {
      process.exitCode = 1;
    } else if (interrupt.signal.aborted) {
      process.exitCode = 130;
    } else {
      process.exitCode = printError(error, target);
    }
  } finally {
    process.off("SIGINT", interrupted);
    process.off("SIGTERM", interrupted);
  }
}

await main();
