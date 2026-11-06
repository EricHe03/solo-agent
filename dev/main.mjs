import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

import { apps, coreDevice } from "@swipt/cli/coredevice.mjs";
import { FalseResult } from "@swipt/cli/output.mjs";
import {
  bundleId,
  installAndOpen,
  installPasscode,
} from "@swipt/cli/sideload.mjs";

import { buildExpoModulesCore } from "./expo-modules-core.mjs";
import { syncLocales } from "./strings.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app = path.join(
  root,
  "build/DerivedData/Build/Products/Debug-iphoneos/Swipt.app",
);

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

async function installApp(context) {
  const device = await coreDevice(context, { required: false });
  const current = (await apps(device.udid)).find(
    (it) => it.bundleIdentifier === bundleId,
  );
  const passcode = await installPasscode(context, current);
  const stamp = Math.floor(Date.now() / 1000);
  run("make", ["lib", "server", "build_ios"], {
    XCODEBUILD_FLAGS: [
      process.env.XCODEBUILD_FLAGS,
      `CURRENT_PROJECT_VERSION=${stamp}`,
    ]
      .filter(Boolean)
      .join(" "),
  });
  await installAndOpen(context, { device, id: bundleId, current }, app, stamp, {
    passcode,
  });
}

const commands = [
  [
    "frameworks",
    "Build ExpoModulesCore from its patched sources and install the React Native frameworks that the Xcode project links",
  ],
  [
    "install [-d NAME|UDID]",
    "Run make lib server build_ios, install the app on the device, check the installed build, and set it up",
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
install reinstalls on every run and sets Swipt up like swipt sideload install; --passcode, --passcode-type, --no-setup, --no-setup-pair and --no-setup-api work the same.
install fails when the build number installed on the device differs from the one just built.`;

async function main() {
  const { values: options, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      device: { type: "string", short: "d" },
      passcode: { type: "string" },
      "passcode-type": { type: "string" },
      "no-setup": { type: "boolean" },
      "no-setup-pair": { type: "boolean" },
      "no-setup-api": { type: "boolean" },
    },
  });
  const [command] = positionals;
  switch (command) {
    case "frameworks":
      frameworks();
      break;
    case "install":
      await installApp({ options, signal: interrupt.signal });
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
  if (error instanceof FalseResult) {
    process.exitCode = 1;
  } else if (interrupt.signal.aborted || error.name === "ExitPromptError") {
    process.exitCode = 130;
  } else {
    console.error("error:", error.message);
    process.exitCode = 1;
  }
}
