import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { label, sameName } from "./connection.mjs";
import { choose, interactive, step } from "./output.mjs";

const exec = promisify(execFile);

const xcodeMissing =
  "Xcode is missing; install it from the App Store, open it once, and select it with xcode-select";

export async function devicectl(args, { parse = false } = {}) {
  const output = parse
    ? path.join(os.tmpdir(), `devicectl-${randomUUID()}.json`)
    : undefined;
  try {
    await exec(
      "xcrun",
      ["devicectl", ...args, ...(parse ? ["--json-output", output] : [])],
      { maxBuffer: Infinity },
    );
  } catch (error) {
    if (error.code === "ENOENT") {
      throw new Error(xcodeMissing);
    }
    if (typeof error.code !== "number") {
      throw error;
    }
    const text = `${error.stdout}${error.stderr}`;
    if (/^(xcrun|xcode-select): /m.test(text)) {
      throw new Error(`${xcodeMissing} (${text.trim()})`);
    }
    if (text.includes("4016")) {
      throw new Error(
        "CoreDevice cannot reach the device while its loopback VPN is on; turn off Swipt's VPN on the device, then run this again",
      );
    }
    throw new Error(text.trim() || `devicectl exited with ${error.code}`);
  }
  if (!parse) {
    return undefined;
  }
  const parsed = JSON.parse(fs.readFileSync(output, "utf8"));
  fs.rmSync(output);
  return parsed;
}

const reachability =
  "unlock the device and connect it with USB or the same network as this Mac";

const deviceLine = (device) =>
  `  ${device.name}  ${device.udid}${device.offline ? "  (offline)" : ""}`;

export async function coreDevice(context, { required = true, filter } = {}) {
  const given = context.options.device;
  const listed = await step(
    "looking for devices",
    () => devicectl(["list", "devices"], { parse: true }),
    { transient: true },
  );
  const paired = listed.result.devices
    .filter(
      (device) =>
        device.hardwareProperties.platform === "iOS" &&
        ["physical", undefined].includes(device.hardwareProperties.reality),
    )
    .map((device) => ({
      name: device.deviceProperties.name,
      udid: device.hardwareProperties.udid,
      offline: device.connectionProperties.tunnelState === "unavailable",
    }));
  const named = (device) =>
    sameName(device.udid, given) || sameName(label(device.name), label(given));
  const devices = paired.filter((device) => !device.offline);
  const matches = given ? devices.filter(named) : devices;
  if ((given || !required) && matches.length === 1) {
    return matches[0];
  }
  if (paired.length === 0) {
    throw new Error(
      "no iOS device is paired with this Mac; connect one with USB, unlock it, and trust this Mac",
    );
  }
  const offline = given && paired.find(named);
  if (matches.length === 0 && offline) {
    throw new Error(`${offline.name} is offline; ${reachability}`);
  }
  if (devices.length === 0) {
    throw new Error(
      `every paired iOS device is offline; ${reachability}:\n${paired.map(deviceLine).join("\n")}`,
    );
  }
  const reason = !given
    ? "choose a device with -d NAME|UDID"
    : matches.length === 0
      ? `no iOS device is named ${given}`
      : `more than one iOS device is named ${given}; choose one by UDID`;
  const failure = new Error(
    `${reason}; paired iOS devices:\n${paired.map(deviceLine).join("\n")}`,
  );
  if (matches.length === 0) {
    throw failure;
  }
  const choices =
    filter !== undefined && interactive(context)
      ? await filter(matches)
      : matches;
  return choose(
    context,
    "Choose a device",
    choices.map((device) => ({
      name: `${device.name}  ${device.udid}`,
      short: device.name,
      value: device,
    })),
    failure,
  );
}

export const apps = async (udid) =>
  (
    await devicectl(["device", "info", "apps", "--device", udid], {
      parse: true,
    })
  ).result.apps;

export const provisioningProfiles = async (udid) =>
  (
    await devicectl(
      ["device", "profile", "list", "--type", "provisioning", "--device", udid],
      { parse: true },
    )
  ).result.provisioningProfiles;
