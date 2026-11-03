import dgram from "node:dgram";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";

import Bonjour from "bonjour-service";

import { Code, RpcError, UsageError, open } from "./client.mjs";
import { columns, enumText } from "./output.mjs";
import {
  DeviceConnectionProblem,
  DeviceConnectionProblemSchema,
  DeviceConnectionStateSchema,
} from "./proto/common_pb.js";

const browseLimit = 1500;
const browseRequery = 300;

const storeFile = path.join(
  process.env.XDG_CONFIG_HOME || path.join(os.homedir(), ".config"),
  "swipt",
  "devices.json",
);

function load() {
  let text;
  try {
    text = fs.readFileSync(storeFile, "utf8");
  } catch (error) {
    if (error.code === "ENOENT") {
      return {};
    }
    throw error;
  }
  return JSON.parse(text);
}

function save(devices) {
  fs.mkdirSync(path.dirname(storeFile), { recursive: true, mode: 0o700 });
  fs.writeFileSync(storeFile, `${JSON.stringify(devices, null, 2)}\n`, {
    mode: 0o600,
  });
}

export function label(name) {
  const slug = [...name.replaceAll(/['’]/g, "")]
    .map((character) => (/[A-Za-z0-9]/.test(character) ? character : "-"))
    .join("")
    .split("-")
    .filter((part) => part !== "")
    .join("-");
  return slug === "" ? name : slug;
}

export const sameName = (a, b) => a.toLowerCase() === b.toLowerCase();

const storedName = (stored, name) =>
  Object.keys(stored).find((it) => sameName(it, name));

function parseURL(text) {
  let parsed;
  try {
    parsed = new URL(text.includes("://") ? text : `http://${text}`);
  } catch {
    throw new UsageError(`${text} is not a URL`);
  }
  if (
    parsed.hostname === "" ||
    (parsed.protocol !== "http:" && parsed.protocol !== "https:")
  ) {
    throw new UsageError(`${text} is not an http or https URL`);
  }
  let token;
  try {
    token = decodeURIComponent(parsed.username);
  } catch {
    token = parsed.username;
  }
  return {
    url: `${parsed.protocol}//${parsed.host}${parsed.pathname.replace(/\/+$/, "")}`,
    token,
  };
}

export const withToken = (url) => url.replace("://", "://TOKEN@");

async function browse(signal, until) {
  const bonjour = new Bonjour({
    socket: dgram.createSocket("udp4"),
    bind: false,
  });
  const found = new Map();
  const enough = new AbortController();
  try {
    const browser = bonjour.find({ type: "swipt" }, (service) => {
      if (!service.host || found.has(service.name)) {
        return;
      }
      const host = service.host.replace(/\.$/, "").toLowerCase();
      found.set(service.name, {
        name: label(service.name),
        url: `http://${host.includes(":") ? `[${host}]` : host}:${service.port}`,
        authenticates: service.txt?.auth === "1",
      });
      if (until?.([...found.values()])) {
        enough.abort();
      }
    });
    const requery = setInterval(() => browser.update(), browseRequery);
    try {
      await sleep(browseLimit, undefined, {
        signal: AbortSignal.any([signal, enough.signal]),
      });
    } catch (error) {
      if (signal.aborted) {
        throw error;
      }
    } finally {
      clearInterval(requery);
    }
    browser.stop();
  } finally {
    bonjour.destroy();
  }
  return [...found.values()];
}

async function discover(signal, stored, until) {
  const found = await browse(signal, until);
  let changed = false;
  for (const it of found) {
    if (it.authenticates) {
      continue;
    }
    const name = storedName(stored, it.name);
    if (name === undefined) {
      stored[it.name] = it.url;
      changed = true;
    } else {
      const current = parseURL(stored[name]);
      if (current.token === "" && current.url !== it.url) {
        stored[name] = it.url;
        changed = true;
      }
    }
  }
  if (changed) {
    save(stored);
  }
  return found;
}

const requiresToken = (found) =>
  `${found.name} requires a token: swipt device add ${withToken(found.url)}`;

export async function attach(context) {
  const given = context.options.device ?? process.env.SWIPT_DEVICE;
  const stored = load();
  let device;
  if (given && /[:/]/.test(given)) {
    device = parseURL(given);
  } else if (given) {
    const name = label(given);
    let known = storedName(stored, name);
    if (known === undefined) {
      const found = (
        await discover(context.signal, stored, (services) =>
          services.some((it) => sameName(it.name, name)),
        )
      ).find((it) => sameName(it.name, name));
      if (!found) {
        throw new Error(
          `there is no device ${name}; "swipt device list" lists them`,
        );
      }
      if (found.authenticates) {
        throw new Error(requiresToken(found));
      }
      known = found.name;
    }
    device = parseURL(stored[known]);
  } else {
    let found = [];
    if (Object.keys(stored).length === 0) {
      found = await discover(context.signal, stored);
    }
    const names = Object.keys(stored);
    if (names.length === 0) {
      const locked = found.filter((it) => it.authenticates);
      if (locked.length > 0) {
        throw new Error(locked.map(requiresToken).join("\n"));
      }
      throw new Error(
        'there is no device; turn on Swipt › Developer › Local Network, or connect one with "swipt device add URL"',
      );
    }
    if (names.length > 1) {
      throw new Error(
        `there is more than one device: ${names.join(", ")}; choose one with -d or SWIPT_DEVICE`,
      );
    }
    device = parseURL(stored[names[0]]);
  }
  context.target.url = device.url;
  return open(device);
}

function connectionText(connection) {
  let text = enumText(
    DeviceConnectionStateSchema,
    connection?.state ?? 0,
    "DEVICE_CONNECTION_STATE_",
  );
  if (
    connection &&
    connection.problem !== DeviceConnectionProblem.UNSPECIFIED
  ) {
    text += `, ${enumText(DeviceConnectionProblemSchema, connection.problem, "DEVICE_CONNECTION_PROBLEM_")}`;
  }
  if (connection?.message) {
    text += `: ${connection.message}`;
  }
  return text;
}

async function probe(url, signal) {
  try {
    const info = await open(parseURL(url)).system.getInfo({}, { signal });
    return [
      `${info.appVersion} (${info.appBuild})`,
      connectionText(info.deviceConnection),
    ];
  } catch (error) {
    return [
      error instanceof RpcError && error.code === Code.Unauthenticated
        ? "requires a token"
        : "offline",
    ];
  }
}

export async function list({ signal }) {
  const stored = load();
  const deadline = AbortSignal.any([signal, AbortSignal.timeout(browseLimit)]);
  const probes = new Map(
    Object.values(stored).map((url) => [url, probe(url, deadline)]),
  );
  await discover(signal, stored);
  const names = Object.keys(stored).sort((a, b) => a.localeCompare(b));
  if (names.length === 0) {
    console.error(
      'no device publishes Swipt on the local network; turn on Swipt › Developer › Local Network, or connect one with "swipt device add URL"',
    );
    return;
  }
  const late = AbortSignal.any([signal, AbortSignal.timeout(browseLimit)]);
  const rows = await Promise.all(
    names.map(async (name) => [
      name,
      parseURL(stored[name]).url,
      ...(await (probes.get(stored[name]) ?? probe(stored[name], late))),
    ]),
  );
  console.log(columns(rows));
}

export async function add(context) {
  const device = parseURL(context.args[0]);
  context.target.url = device.url;
  const info = await open(device).system.getInfo(
    {},
    { signal: context.signal },
  );
  const name = label(info.deviceName) || new URL(device.url).hostname;
  const stored = load();
  const previous = storedName(stored, name);
  if (previous !== undefined) {
    delete stored[previous];
  }
  stored[name] = context.args[0];
  save(stored);
  console.log("added", name);
}

export function remove({ args }) {
  const stored = load();
  const name = storedName(stored, label(args[0]));
  if (name === undefined) {
    throw new Error(`there is no device ${args[0]}`);
  }
  delete stored[name];
  save(stored);
  console.log("removed", name);
}
