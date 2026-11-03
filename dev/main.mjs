import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";

import { attach, label, sameName } from "@swipt/cli/connection.mjs";

import { buildExpoModulesCore } from "./expo-modules-core.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const runtime = path.join(root, "internal/automation/runtime");
const derivedData = path.join(root, "build/DerivedData");
const uiBundle = path.join(root, "build/runtime/main.jsbundle");
const bundleId = "io.nekohasekai.swipt";

const interrupt = new AbortController();
process.on("SIGINT", () => interrupt.abort());

function run(command, args, { cwd = root, env, stdout = "inherit" } = {}) {
  const result = spawnSync(command, args, { cwd, env: env === undefined ? process.env : { ...process.env, ...env }, stdio: ["inherit", stdout, "inherit"], encoding: "utf8" });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(`${[command, ...args].join(" ")} exited with ${result.status ?? `signal ${result.signal}`}`);
  }
  return result.stdout;
}

const install = () => run("bun", ["install", "--frozen-lockfile"]);

const buildRuntime = () => {
  install();
  run("bun", ["build.mjs"], { cwd: runtime });
};

const buildLib = () => run("go", ["run", "./internal/cmd/build_libswipt"]);

const proto = () => {
  install();
  run("go", ["run", "./internal/cmd/protogen"]);
  run("gofumpt", ["-w", "internal/proto"]);
};

const frameworks = () => {
  install();
  // ExpoModulesCore builds against the frameworks update links, and update links the ExpoModulesCore it finds.
  const update = () => run("node", ["node_modules/react-native/scripts/setup-apple-spm.js", "update", "--product-name", "Swipt", "--yes"]);
  update();
  if (buildExpoModulesCore()) {
    update();
  }
};

function* walk(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      yield* walk(file);
    } else {
      yield file;
    }
  }
}

function buildUI() {
  const inputs = [
    ...walk(path.join(runtime, "src")),
    ...walk(path.join(runtime, "patches")),
    path.join(runtime, "package.json"),
    path.join(runtime, "app.json"),
    path.join(runtime, "babel.config.js"),
    path.join(runtime, "metro.config.js"),
    path.join(runtime, "metro.transformer.js"),
    path.join(runtime, "slots.mjs"),
    path.join(root, "package.json"),
    path.join(root, "bun.lock"),
  ].sort();
  const digest = crypto.createHash("sha256");
  for (const file of inputs) {
    digest.update(path.relative(root, file)).update("\0").update(fs.readFileSync(file)).update("\0");
  }
  const stamp = digest.digest("hex");
  const stampFile = `${uiBundle}.inputs`;
  if (fs.existsSync(uiBundle) && fs.existsSync(stampFile) && fs.readFileSync(stampFile, "utf8") === stamp) {
    return;
  }
  const output = path.dirname(uiBundle);
  fs.mkdirSync(output, { recursive: true });
  run("bun", ["expo", "export:embed", "--platform", "ios", "--dev", "false", "--minify", "false", "--entry-file", "src/app/index.tsx", "--bundle-output", path.join(output, "main.js"), "--assets-dest", path.join(output, "assets")], { cwd: runtime, env: { CI: "1" } });
  run(path.join(root, "node_modules/hermes-compiler/hermesc/osx-bin/hermesc"), ["-emit-binary", "-O", "-w", "-out", uiBundle, path.join(output, "main.js")]);
  fs.writeFileSync(stampFile, stamp);
}

function xcodebuild(args) {
  fs.mkdirSync(path.join(root, "build"), { recursive: true });
  const log = path.join(root, "build/xcodebuild.log");
  const result = spawnSync("xcodebuild", [...args, "-skipMacroValidation", "-derivedDataPath", derivedData, ...(process.env.XCODEBUILD_FLAGS ?? "").split(" ").filter(Boolean)], { cwd: root, stdio: ["inherit", fs.openSync(log, "w"), "inherit"] });
  if (result.status !== 0) {
    spawnSync("xcbeautify", ["--quiet"], { cwd: root, stdio: [fs.openSync(log, "r"), "inherit", "inherit"] });
    throw new Error(`xcodebuild exited with ${result.status ?? `signal ${result.signal}`}; the full log is ${path.relative(root, log)}`);
  }
}

const platforms = {
  ios: { scheme: "Swipt", destination: "generic/platform=iOS", product: "Debug-iphoneos/Swipt.app" },
  macos: { scheme: "Swipt macOS", destination: "generic/platform=macOS", product: "Debug/Swipt.app" },
};

function build(platform = "ios", settings = []) {
  const target = platforms[platform];
  if (target === undefined) {
    throw new Error(`the platform must be one of ${Object.keys(platforms).join(", ")}`);
  }
  if (platform === "ios") {
    buildUI();
  }
  xcodebuild(["build", "-scheme", target.scheme, "-configuration", "Debug", "-destination", target.destination, ...settings]);
  const app = path.join(derivedData, "Build/Products", target.product);
  console.log(path.relative(root, app));
  return app;
}

function archive() {
  buildUI();
  const archivePath = path.join(root, "build/Swipt-iOS.xcarchive");
  const payload = path.join(root, "build/Payload");
  fs.rmSync(archivePath, { recursive: true, force: true });
  fs.rmSync(payload, { recursive: true, force: true });
  fs.rmSync(path.join(root, "build/Swipt.ipa"), { force: true });
  xcodebuild(["archive", "-scheme", "Swipt", "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", archivePath, "CODE_SIGNING_ALLOWED=NO"]);
  fs.mkdirSync(payload);
  fs.cpSync(path.join(archivePath, "Products/Applications/Swipt.app"), path.join(payload, "Swipt.app"), { recursive: true });
  run("zip", ["-qry", "Swipt.ipa", "Payload"], { cwd: path.join(root, "build") });
  fs.rmSync(payload, { recursive: true });
  console.log("build/Swipt.ipa");
}

function ipa() {
  buildRuntime();
  buildLib();
  frameworks();
  archive();
}

function icon() {
  const output = path.join(root, "build/altstore");
  fs.rmSync(output, { recursive: true, force: true });
  fs.mkdirSync(output, { recursive: true });
  const file = path.join(output, "icon.png");
  const ictool = path.join(run("xcode-select", ["-p"], { stdout: "pipe" }).trim(), "../Applications/Icon Composer.app/Contents/Executables/ictool");
  run(ictool, [path.join(root, "Swipt/Resources/AppIcon.icon"), "--export-image", "--output-file", file, "--platform", "iOS", "--rendition", "Default", "--width", "568", "--height", "568", "--scale", "1"], { stdout: "ignore" });
  // AltStore draws icons on a white background, clipped to a circle or a height/5 corner radius
  // (AltStore fafd76e, AltStore/Components/AppIconImageView.swift:46-65), so the transparent
  // corners and edge highlight of the exported squircle show up as a white border.
  run("sips", ["--cropToHeightWidth", "512", "512", file], { stdout: "ignore" });
  console.log(path.relative(root, file));
}

function devicectl(args, { parse = false } = {}) {
  const output = parse ? path.join(os.tmpdir(), `devicectl-${process.pid}.json`) : undefined;
  const result = spawnSync("xcrun", ["devicectl", ...args, ...(parse ? ["--json-output", output] : [])], { cwd: root, encoding: "utf8" });
  if (result.status !== 0) {
    const text = `${result.stdout}${result.stderr}`;
    if (text.includes("4016")) {
      throw new Error("CoreDevice cannot reach the device while its loopback VPN is on; turn off Swipt's VPN on the device, then run this again");
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

const infoOf = async client => {
  try {
    return await client.system.getInfo({}, { signal: AbortSignal.any([interrupt.signal, AbortSignal.timeout(5000)]) });
  } catch (error) {
    if (interrupt.signal.aborted) {
      throw error;
    }
    return undefined;
  }
};

async function unlock(client) {
  for await (const response of client.repl.execute({ code: "await device.unlock()", args: [], program: false }, { signal: interrupt.signal })) {
    if (response.part.case === "error") {
      throw new Error(`the device was not unlocked: ${response.part.value.message}`);
    }
  }
}

function coreDevice(given) {
  const devices = devicectl(["list", "devices"], { parse: true }).result.devices
    .filter(device => device.hardwareProperties.platform === "iOS" && device.hardwareProperties.reality === "physical")
    .map(device => ({ name: device.deviceProperties.name, udid: device.hardwareProperties.udid }));
  const matches = given ? devices.filter(device => sameName(device.udid, given) || sameName(label(device.name), label(given))) : devices;
  if (matches.length !== 1) {
    const found = matches.length === 0 ? "no" : "more than one";
    throw new Error(given ? `${found} iOS device is named ${given}` : `${found} iOS device is paired; choose one with -d NAME|UDID`);
  }
  return matches[0];
}

async function swipt(name) {
  try {
    const client = await attach({ options: { device: label(name) }, target: { url: "" }, signal: interrupt.signal });
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
  buildRuntime();
  buildLib();
  const app = build("ios", [`CURRENT_PROJECT_VERSION=${stamp}`]);

  const client = await swipt(device.name);
  if (client !== undefined) {
    await unlock(client).catch(() => {});
  }
  devicectl(["device", "install", "app", "--device", device.udid, app]);
  devicectl(["device", "process", "launch", "--terminate-existing", "--device", device.udid, bundleId]);
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
  ["proto", "Regenerate the Go and JavaScript gRPC code from internal/proto"],
  ["encodings", "Regenerate the runtime's encoding labels and indexes from the WHATWG Encoding Standard"],
  ["runtime", "Build the SDK runtime that libswipt embeds (internal/automation/runtime.js, its chunks and the declarations)"],
  ["lib", "Build the runtime, then libswipt into Frameworks/LibSwipt.xcframework"],
  ["ui", "Bundle the Swiplet UI runtime into build/runtime/main.jsbundle when its inputs changed"],
  ["frameworks", "Build ExpoModulesCore from its patched sources and install the React Native frameworks that the Xcode project links"],
  ["build [ios|macos]", "Build the Debug app into build/DerivedData; ios also runs ui (default: ios)"],
  ["archive", "Archive Release with the built lib and frameworks into build/Swipt.ipa; also runs ui"],
  ["ipa", "Build runtime, lib and frameworks, then archive"],
  ["icon", "Export the AltStore icon into build/altstore/icon.png"],
  ["install [-d NAME|UDID]", "Build runtime, lib and the ios app, then install and launch it on the device"],
];

const usage = `usage: bun dev COMMAND

commands:
${commands.map(([use, help]) => `  ${use.padEnd(38)}${help}`).join("\n")}

install picks the paired iOS device that -d or SWIPT_DEVICE names by CoreDevice name or UDID, or the only one; when Swipt answers on it, it unlocks the device first.
XCODEBUILD_FLAGS adds flags to every xcodebuild run.`;

async function main() {
  const { options, positional } = parse(process.argv.slice(2));
  const [command, ...rest] = positional;
  if (command === undefined || !commands.some(([use]) => use.split(" ")[0] === command)) {
    console.log(usage);
    process.exitCode = command === undefined ? 0 : 2;
    return;
  }
  switch (command) {
    case "proto":
      proto();
      break;
    case "encodings":
      run("bun", ["encodings.mjs"], { cwd: runtime });
      break;
    case "runtime":
      buildRuntime();
      break;
    case "lib":
      buildRuntime();
      buildLib();
      break;
    case "ui":
      buildUI();
      break;
    case "frameworks":
      frameworks();
      break;
    case "build":
      build(rest[0]);
      break;
    case "archive":
      archive();
      break;
    case "ipa":
      ipa();
      break;
    case "icon":
      icon();
      break;
    case "install":
      await installApp(options);
      break;
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
