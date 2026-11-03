import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { attach, label, sameName } from "@swipt/cli/connection.mjs";

import { buildExpoModulesCore } from "./expo-modules-core.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app = path.join(
  root,
  "build/DerivedData/Build/Products/Debug-iphoneos/Swipt.app",
);
const bundleId = "io.nekohasekai.swipt";

const interrupt = new AbortController();
process.on("SIGINT", () => interrupt.abort());

function run(command, args, env) {
  const result = spawnSync(command, args, {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: "inherit",
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${[command, ...args].join(" ")} exited with ${result.status ?? `signal ${result.signal}`}`,
    );
  }
}

const frameworks = () => {
  run("bun", ["install", "--frozen-lockfile"]);
  // ExpoModulesCore builds against the frameworks update links, and update links the ExpoModulesCore it finds.
  const update = () =>
    run("node", [
      "node_modules/react-native/scripts/setup-apple-spm.js",
      "update",
      "--product-name",
      "Swipt",
      "--yes",
    ]);
  update();
  if (buildExpoModulesCore()) {
    update();
  }
};

function devicectl(args, { parse = false } = {}) {
  const output = parse
    ? path.join(os.tmpdir(), `devicectl-${process.pid}.json`)
    : undefined;
  const result = spawnSync(
    "xcrun",
    ["devicectl", ...args, ...(parse ? ["--json-output", output] : [])],
    { cwd: root, encoding: "utf8" },
  );
  if (result.status !== 0) {
    const text = `${result.stdout}${result.stderr}`;
    if (text.includes("4016")) {
      throw new Error(
        "CoreDevice cannot reach the device while its loopback VPN is on; turn off Swipt's VPN on the device, then run this again",
      );
    }
    throw new Error(text.trim() || `devicectl exited with ${result.status}`);
  }
  if (!parse) {
    return undefined;
  }
  const parsed = JSON.parse(fs.readFileSync(output, "utf8"));
  fs.rmSync(output);
  return parsed;
}

const infoOf = async (client) => {
  try {
    return await client.system.getInfo(
      {},
      {
        signal: AbortSignal.any([interrupt.signal, AbortSignal.timeout(5000)]),
      },
    );
  } catch (error) {
    if (interrupt.signal.aborted) {
      throw error;
    }
    return undefined;
  }
};

async function unlock(client) {
  for await (const response of client.repl.execute(
    { code: "await device.unlock()", args: [], program: false },
    { signal: interrupt.signal },
  )) {
    if (response.part.case === "error") {
      throw new Error(
        `the device was not unlocked: ${response.part.value.message}`,
      );
    }
  }
}

function coreDevice(given) {
  const devices = devicectl(["list", "devices"], { parse: true })
    .result.devices.filter(
      (device) =>
        device.hardwareProperties.platform === "iOS" &&
        device.hardwareProperties.reality === "physical",
    )
    .map((device) => ({
      name: device.deviceProperties.name,
      udid: device.hardwareProperties.udid,
    }));
  const matches = given
    ? devices.filter(
        (device) =>
          sameName(device.udid, given) ||
          sameName(label(device.name), label(given)),
      )
    : devices;
  if (matches.length !== 1) {
    const found = matches.length === 0 ? "no" : "more than one";
    throw new Error(
      given
        ? `${found} iOS device is named ${given}`
        : `${found} iOS device is paired; choose one with -d NAME|UDID`,
    );
  }
  return matches[0];
}

async function swipt(name) {
  try {
    const client = await attach({
      options: { device: label(name) },
      target: { url: "" },
      signal: interrupt.signal,
    });
    return (await infoOf(client)) === undefined ? undefined : client;
  } catch (error) {
    if (interrupt.signal.aborted) {
      throw error;
    }
    return undefined;
  }
}

async function installApp(options) {
  const device = coreDevice(options.device ?? process.env.SWIPT_DEVICE);
  const stamp = String(Math.floor(Date.now() / 1000));
  run("make", ["lib", "build_ios"], {
    XCODEBUILD_FLAGS: [
      process.env.XCODEBUILD_FLAGS,
      `CURRENT_PROJECT_VERSION=${stamp}`,
    ]
      .filter(Boolean)
      .join(" "),
  });

  const client = await swipt(device.name);
  if (client !== undefined) {
    await unlock(client).catch(() => {});
  }
  devicectl(["device", "install", "app", "--device", device.udid, app]);
  devicectl([
    "device",
    "process",
    "launch",
    "--terminate-existing",
    "--device",
    device.udid,
    bundleId,
  ]);

  const installed = devicectl(
    [
      "device",
      "info",
      "apps",
      "--device",
      device.udid,
      "--bundle-id",
      bundleId,
    ],
    { parse: true },
  ).result.apps;
  if (installed.length !== 1) {
    throw new Error(
      `${device.name} does not list ${bundleId} after the install`,
    );
  }
  const { version, bundleVersion } = installed[0];
  if (bundleVersion !== stamp) {
    throw new Error(
      `${device.name} has Swipt build ${bundleVersion} installed, not the one just built (${stamp})`,
    );
  }
  console.log(
    `Swipt ${version} (${bundleVersion}) is installed and launched on ${device.name}`,
  );
}

function parse(argv) {
  const options = {};
  const positional = [];
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    const named = argument.match(/^--?([a-z]+)(?:=(.*))?$/);
    if (named === null) {
      positional.push(argument);
      continue;
    }
    const name = { d: "device" }[named[1]] ?? named[1];
    options[name] = named[2] ?? argv[++index];
  }
  return { options, positional };
}

const commands = [
  [
    "frameworks",
    "Build ExpoModulesCore from its patched sources and install the React Native frameworks that the Xcode project links",
  ],
  [
    "install [-d NAME|UDID]",
    "Run make lib build_ios, install and launch the app on the device, and check the installed build",
  ],
];

const usage = `usage: bun dev COMMAND

commands:
${commands.map(([use, help]) => `  ${use.padEnd(26)}${help}`).join("\n")}

install picks the paired iOS device that -d or SWIPT_DEVICE names by CoreDevice name or UDID, or the only one; when Swipt answers on it, it unlocks the device first.
install fails when the build number installed on the device differs from the one just built.`;

async function main() {
  const { options, positional } = parse(process.argv.slice(2));
  const [command] = positional;
  switch (command) {
    case "frameworks":
      frameworks();
      break;
    case "install":
      await installApp(options);
      break;
    default:
      console.log(usage);
      process.exitCode = command === undefined ? 0 : 2;
  }
}

try {
  await main();
} catch (error) {
  if (interrupt.signal.aborted) {
    process.exitCode = 130;
  } else {
    console.error("error:", error.message);
    process.exitCode = 1;
  }
}
