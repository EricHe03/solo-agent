import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { runningSwipt, tryUnlock } from "@swipt/cli/connection.mjs";
import { apps, coreDevice, devicectl } from "@swipt/cli/coredevice.mjs";
import { launchUnlocking } from "@swipt/cli/sideload.mjs";

import { buildExpoModulesCore } from "./expo-modules-core.mjs";
import { syncLocales } from "./strings.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app = path.join(
  root,
  "build/DerivedData/Build/Products/Debug-iphoneos/Swipt.app",
);
const bundleId = "io.nekohasekai.swipt";

const interrupt = new AbortController();
process.on("SIGINT", () => interrupt.abort());
process.env.PATH = `${path.join(root, "build")}${path.delimiter}${process.env.PATH}`;

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

async function installApp(options) {
  const device = await coreDevice({ options }, { required: false });
  const stamp = String(Math.floor(Date.now() / 1000));
  run("make", ["lib", "server", "build_ios"], {
    XCODEBUILD_FLAGS: [
      process.env.XCODEBUILD_FLAGS,
      `CURRENT_PROJECT_VERSION=${stamp}`,
    ]
      .filter(Boolean)
      .join(" "),
  });

  const client = await runningSwipt(device.name, interrupt.signal);
  if (client !== undefined) {
    await tryUnlock(client, interrupt.signal);
  }
  await devicectl(["device", "install", "app", "--device", device.udid, app]);
  await launchUnlocking(device, bundleId, [], interrupt.signal);

  const installed = (await apps(device.udid)).filter(
    (app) => app.bundleIdentifier === bundleId,
  );
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
    "Run make lib server build_ios, install and launch the app on the device, and check the installed build",
  ],
  [
    "strings",
    "Check cli/locales against the strings of the CLI and remove the stale ones",
  ],
];

const usage = `usage: bun dev COMMAND

commands:
${commands.map(([use, help]) => `  ${use.padEnd(26)}${help}`).join("\n")}

install picks the paired iOS device that -d names by CoreDevice name or UDID, or the only one; when Swipt answers on it, it unlocks the device first; otherwise a locked device is unlocked with the passcode saved in Swipt.
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
    case "strings":
      syncLocales(path.join(root, "cli"));
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
