import { execFile, execFileSync, spawn } from "node:child_process";
import { X509Certificate, createHash } from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { promisify } from "node:util";

import password from "@inquirer/password";
import select from "@inquirer/select";

import { UsageError, open } from "./client.mjs";
import {
  apps,
  coreDevice,
  devicectl,
  provisioningProfiles,
} from "./coredevice.mjs";
import { language, tr } from "./i18n.mjs";
import {
  choose,
  interactive,
  printScriptError,
  selectTheme,
  step,
} from "./output.mjs";
import { LogLevel } from "./proto/common_pb.js";

const exec = promisify(execFile);

const bundleId = "io.nekohasekai.swipt";
const repository = "swipt-automation/swipt";
const teamPattern = /^[A-Z0-9]{10}$/;
const sideloadedPattern = new RegExp(
  `^${bundleId.replaceAll(".", "\\.")}\\.([A-Z0-9]{10})$`,
);

const accountsHint = "Xcode › Settings › Accounts";
const xcodeProfiles = "Library/Developer/Xcode/UserData/Provisioning Profiles";

const expiresSoon = ({ creation, expiration }) =>
  expiration - Date.now() < (expiration - creation) / 2;

const passcodeTypes = ["pin", "numeric", "alphanumeric"];

const plistValueMissing = /No value at that key path/;

function passcodeOf(options) {
  const type = options["passcode-type"] ?? "pin";
  if (!passcodeTypes.includes(type)) {
    throw new UsageError(
      tr("invalid argument {value} for --passcode-type: it is {types}", {
        value: JSON.stringify(type),
        types: passcodeTypes.join(", "),
      }),
    );
  }
  const passcode = options.passcode;
  if (!passcode) {
    return undefined;
  }
  const digits = /^\d+$/.test(passcode);
  if (type === "pin" && !(digits && [4, 6].includes(passcode.length))) {
    throw new UsageError(
      tr(
        "a pin passcode is 4 or 6 digits; a custom one needs --passcode-type numeric or alphanumeric",
      ),
    );
  }
  if (type === "numeric" && !digits) {
    throw new UsageError(tr("a numeric passcode is digits only"));
  }
  if (!/^[\x20-\x7e]{1,64}$/.test(passcode)) {
    throw new UsageError(
      tr("a passcode is up to 64 printable ASCII characters"),
    );
  }
  return { passcode, type };
}

function headers(accept) {
  const token = process.env.GITHUB_TOKEN;
  return {
    Accept: accept,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "swipt-cli",
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  };
}

async function github(url, accept, signal) {
  let response = await fetch(url, {
    headers: headers(accept),
    signal,
    redirect: "manual",
  });
  if (response.status >= 300 && response.status < 400) {
    response = await fetch(response.headers.get("location"), { signal });
  }
  if (!response.ok) {
    let message = `GitHub answered ${response.status} for ${url}`;
    if ([401, 403, 429].includes(response.status)) {
      message += `; ${process.env.GITHUB_TOKEN ? "GITHUB_TOKEN" : "set GITHUB_TOKEN to a token that"} must read the repository and stay under the rate limit`;
    }
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return response;
}

async function findRelease(nightly, signal) {
  const read = async (name) =>
    (
      await github(
        `https://api.github.com/repos/${repository}/releases/${name}`,
        "application/vnd.github+json",
        signal,
      )
    ).json();
  const release = nightly
    ? await read("tags/nightly")
    : await read("latest").catch((error) => {
        if (error.status !== 404) {
          throw error;
        }
        return read("tags/nightly");
      });
  const asset = (name) => {
    const found = release.assets.find((it) => it.name === name);
    if (!found) {
      throw new Error(`release ${release.tag_name} has no ${name}`);
    }
    return found.url;
  };
  const metadata = await (
    await github(asset("metadata.json"), "application/octet-stream", signal)
  ).json();
  return {
    tag: release.tag_name,
    version: metadata.version,
    build: Number(metadata.build),
    ipa: asset("Swipt.ipa"),
  };
}

async function download(url, file, signal, update) {
  const response = await github(url, "application/octet-stream", signal);
  const total = Number(response.headers.get("content-length"));
  const megabytes = (bytes) => (bytes / 1_000_000).toFixed(1);
  let received = 0;
  await pipeline(
    Readable.fromWeb(response.body),
    async function* (source) {
      for await (const chunk of source) {
        received += chunk.length;
        update(
          total > 0
            ? `${megabytes(received)} / ${megabytes(total)} MB  ${Math.floor((received / total) * 100)}%`
            : `${megabytes(received)} MB`,
        );
        yield chunk;
      }
    },
    fs.createWriteStream(file),
    { signal },
  );
}

async function unpack(ipa, directory) {
  await exec("unzip", ["-q", ipa, "-d", directory]);
  const payload = path.join(directory, "Payload");
  const app = fs.readdirSync(payload).find((name) => name.endsWith(".app"));
  if (app === undefined) {
    throw new Error("the IPA has no app in Payload");
  }
  return path.join(payload, app);
}

const pbxproj = (id, team) => `// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {
		A1 = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = main.c; sourceTree = "<group>"; };
		A2 = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Stub.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A3 = {isa = PBXBuildFile; fileRef = A1; };
		B1 = {isa = PBXGroup; children = (B2, B3); sourceTree = "<group>"; };
		B2 = {isa = PBXGroup; children = (A1); path = Stub; sourceTree = "<group>"; };
		B3 = {isa = PBXGroup; children = (A2); name = Products; sourceTree = "<group>"; };
		C1 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A3); runOnlyForDeploymentPostprocessing = 0; };
		D1 = {
			isa = PBXNativeTarget;
			buildConfigurationList = E1;
			buildPhases = (C1);
			buildRules = ();
			dependencies = ();
			name = Stub;
			productName = Stub;
			productReference = A2;
			productType = "com.apple.product-type.application";
		};
		E1 = {isa = XCConfigurationList; buildConfigurations = (F1); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		E2 = {isa = XCConfigurationList; buildConfigurations = (F2); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		F1 = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				DEVELOPMENT_TEAM = "${team}";
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.4;
				PRODUCT_BUNDLE_IDENTIFIER = "${id}";
				PRODUCT_NAME = Stub;
				SDKROOT = iphoneos;
				TARGETED_DEVICE_FAMILY = "1,2";
			};
			name = Release;
		};
		F2 = {isa = XCBuildConfiguration; buildSettings = {}; name = Release; };
		G1 = {
			isa = PBXProject;
			buildConfigurationList = E2;
			compatibilityVersion = "Xcode 14.0";
			mainGroup = B1;
			productRefGroup = B3;
			projectDirPath = "";
			projectRoot = "";
			targets = (D1);
		};
	};
	rootObject = G1;
}
`;

function explain(output, team) {
  const errors = [
    ...new Set(
      output
        .split("\n")
        .filter((line) => /^(xcodebuild: )?error: /.test(line))
        .map((line) => line.replace(/^(xcodebuild: )?error: /, "")),
    ),
  ].join("; ");
  if (/No Accounts?\b/.test(output)) {
    return tr(
      "Xcode has no account for team {team}; sign in with its Apple Account at {accounts}",
      { team, accounts: accountsHint },
    );
  }
  if (/signing certificate|certificateType/i.test(output)) {
    return tr(
      "Xcode could not make a development certificate for team {team}; add one at {accounts} › Manage Certificates ({errors})",
      { team, accounts: accountsHint, errors },
    );
  }
  if (/requires Xcode|xcode-select/.test(output)) {
    return tr(
      "xcodebuild needs Xcode; install it and select it with xcode-select",
    );
  }
  return errors || output.trim();
}

function profileField(file, key) {
  return execFileSync("plutil", ["-extract", key, "raw", "-o", "-", "-"], {
    input: execFileSync("security", ["cms", "-D", "-i", file], {
      stdio: ["ignore", "pipe", "ignore"],
    }),
    encoding: "utf8",
  }).trim();
}

function revoked(certificates) {
  const [leaf, issuer] = [0, 1].map(
    (index) => new X509Certificate(fs.readFileSync(`${certificates}${index}`)),
  );
  const url = /^OCSP - URI:(.+)$/m.exec(leaf.infoAccess ?? "")?.[1];
  if (url === undefined) {
    return false;
  }
  fs.writeFileSync(`${certificates}0.pem`, leaf.toString());
  fs.writeFileSync(`${certificates}1.pem`, issuer.toString());
  try {
    return /: revoked$/m.test(
      execFileSync(
        "openssl",
        [
          "ocsp",
          "-issuer",
          `${certificates}1.pem`,
          "-cert",
          `${certificates}0.pem`,
          "-url",
          url,
          "-noverify",
        ],
        {
          encoding: "utf8",
          stdio: ["ignore", "pipe", "ignore"],
          timeout: 10_000,
        },
      ),
    );
  } catch {
    return false;
  }
}

async function provision(work, id, team, device, update) {
  const stub = path.join(work, "Stub");
  const products = path.join(stub, "Products");
  const app = path.join(products, "Stub.app");
  const profile = path.join(app, "embedded.mobileprovision");
  fs.mkdirSync(path.join(stub, "Stub.xcodeproj"), { recursive: true });
  fs.mkdirSync(path.join(stub, "Stub"));
  fs.writeFileSync(
    path.join(stub, "Stub/main.c"),
    "int main(void) { return 0; }\n",
  );
  fs.writeFileSync(
    path.join(stub, "Stub.xcodeproj/project.pbxproj"),
    pbxproj(id, team),
  );
  const build = async () => {
    const running = exec(
      "xcodebuild",
      [
        "build",
        "-project",
        path.join(stub, "Stub.xcodeproj"),
        "-scheme",
        "Stub",
        "-configuration",
        "Release",
        "-destination",
        `id=${device.udid}`,
        `CONFIGURATION_BUILD_DIR=${products}`,
        `OBJROOT=${path.join(stub, "Objects")}`,
        "-allowProvisioningUpdates",
        "-allowProvisioningDeviceRegistration",
      ],
      { maxBuffer: Infinity },
    );
    running.child.stdout.on("data", (chunk) => {
      const line = String(chunk)
        .split("\n")
        .findLast((it) => /^[A-Z]\w* /.test(it));
      if (line) {
        update(line.split(" ")[0]);
      }
    });
    try {
      await running;
    } catch (error) {
      if (error.code === "ENOENT") {
        throw new Error(tr("xcodebuild is missing; install Xcode"));
      }
      if (typeof error.code !== "number") {
        throw error;
      }
      throw new Error(explain(`${error.stdout}${error.stderr}`, team));
    }
  };
  const certificates = path.join(work, "certificate");
  const stdio = ["ignore", "pipe", "ignore"];
  const extract = () =>
    execFileSync(
      "codesign",
      ["-d", `--extract-certificates=${certificates}`, app],
      { stdio },
    );
  await build();
  extract();
  if (
    expiresSoon({
      creation: Date.parse(profileField(profile, "CreationDate")),
      expiration: Date.parse(profileField(profile, "ExpirationDate")),
    }) ||
    revoked(certificates)
  ) {
    // Xcode keeps a cached profile until it expires, even after its certificate is revoked, and creates a new one once it is removed.
    fs.rmSync(
      path.join(
        os.homedir(),
        xcodeProfiles,
        `${profileField(profile, "UUID")}.mobileprovision`,
      ),
      { force: true },
    );
    await build();
    extract();
  }
  const entitlements = path.join(work, "entitlements.plist");
  fs.writeFileSync(
    entitlements,
    execFileSync("codesign", ["-d", "--entitlements", "-", "--xml", app], {
      stdio,
    }),
  );
  return {
    identity: createHash("sha1")
      .update(fs.readFileSync(`${certificates}0`))
      .digest("hex")
      .toUpperCase(),
    entitlements,
    profile,
  };
}

async function resign(app, id, signing, update) {
  const info = path.join(app, "Info.plist");
  execFileSync("plutil", [
    "-replace",
    "CFBundleIdentifier",
    "-string",
    id,
    info,
  ]);
  let permitted;
  try {
    permitted = JSON.parse(
      execFileSync(
        "plutil",
        [
          "-extract",
          "BGTaskSchedulerPermittedIdentifiers",
          "json",
          "-o",
          "-",
          info,
        ],
        { stdio: "pipe" },
      ),
    );
  } catch (error) {
    if (!plistValueMissing.test(error.stderr)) {
      throw error;
    }
  }
  if (permitted !== undefined) {
    execFileSync("plutil", [
      "-replace",
      "BGTaskSchedulerPermittedIdentifiers",
      "-json",
      JSON.stringify(
        permitted.map((it) =>
          it.startsWith(`${bundleId}.`) ? id + it.slice(bundleId.length) : it,
        ),
      ),
      info,
    ]);
  }
  fs.copyFileSync(signing.profile, path.join(app, "embedded.mobileprovision"));
  const codesign = ["--force", "--sign", signing.identity, "--timestamp=none"];
  const frameworks = path.join(app, "Frameworks");
  if (fs.existsSync(frameworks)) {
    for (const name of fs.readdirSync(frameworks)) {
      update(name);
      await exec("codesign", [...codesign, path.join(frameworks, name)]);
    }
  }
  update(path.basename(app));
  await exec("codesign", [
    ...codesign,
    "--entitlements",
    signing.entitlements,
    app,
  ]);
}

function xcodeTeams() {
  const valid = new Set(
    [
      ...execFileSync(
        "security",
        ["find-identity", "-v", "-p", "codesigning"],
        {
          encoding: "utf8",
        },
      ).matchAll(/\) ([0-9A-F]{40}) "Apple Development: /g),
    ].map((match) => match[1]),
  );
  const certificates = execFileSync(
    "security",
    ["find-certificate", "-a", "-Z", "-p", "-c", "Apple Development"],
    { encoding: "utf8" },
  ).matchAll(
    /SHA-1 hash: ([0-9A-F]{40})[\s\S]*?(-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----)/g,
  );
  const teams = new Map();
  for (const [, hash, pem] of certificates) {
    if (!valid.has(hash)) {
      continue;
    }
    const subject = new X509Certificate(pem).subject;
    const id = /^OU=(.+)$/m.exec(subject)?.[1];
    if (id !== undefined && teamPattern.test(id)) {
      teams.set(id, /^O=(.+)$/m.exec(subject)?.[1].replaceAll("\\", ""));
    }
  }
  return [...teams].map(([id, name]) => ({ id, name }));
}

function xcodeSignedIn() {
  try {
    const lists = JSON.parse(
      execFileSync(
        "plutil",
        [
          "-extract",
          "DVTDeveloperAccountManagerAppleIDLists",
          "json",
          "-o",
          "-",
          "-",
        ],
        {
          input: execFileSync("defaults", [
            "export",
            "com.apple.dt.Xcode",
            "-",
          ]),
          stdio: "pipe",
          encoding: "utf8",
        },
      ),
    );
    return Object.values(lists).some((accounts) => accounts.length > 0);
  } catch (error) {
    if (plistValueMissing.test(error.stderr)) {
      return false;
    }
    throw error;
  }
}

const teamList = (teams) =>
  teams
    .map((team) => `  ${team.id}${team.name ? `  ${team.name}` : ""}`)
    .join("\n");

const teamChoice = ({ id, name }) => ({
  name: name ? `${name}  ${id}` : id,
  short: name ?? id,
  value: id,
});

async function sideloadedDevices(
  devices,
  missing = tr("Swipt is not sideloaded on any online iOS device"),
) {
  const sideloaded = await step(
    tr("looking for Swipt on the devices"),
    () =>
      Promise.all(
        devices.map((device) =>
          apps(device.udid).then(
            (listed) =>
              listed.some((app) =>
                sideloadedPattern.test(app.bundleIdentifier),
              ),
            () => true,
          ),
        ),
      ),
    { transient: true },
  );
  const found = devices.filter((_, index) => sideloaded[index]);
  if (found.length === 0) {
    throw new Error(missing);
  }
  return found;
}

async function locate(context, device, fresh = false) {
  const { options } = context;
  const listed = await step(
    tr("checking Swipt on {device}", { device: device.name }),
    () => apps(device.udid),
    { transient: true },
  );
  const found = listed
    .map((app) => ({
      ...app,
      team: sideloadedPattern.exec(app.bundleIdentifier)?.[1],
    }))
    .filter((app) => app.team !== undefined);
  if (options.team !== undefined) {
    if (!teamPattern.test(options.team)) {
      throw new UsageError(
        tr(
          "invalid argument {value} for --team: it is the 10-character team ID shown in {accounts}",
          { value: JSON.stringify(options.team), accounts: accountsHint },
        ),
      );
    }
    return {
      team: options.team,
      current: found.find((app) => app.team === options.team),
    };
  }
  if (found.length > 1) {
    const known = xcodeTeams();
    const teams = found.map((app) => ({
      id: app.team,
      name: known.find((team) => team.id === app.team)?.name,
    }));
    const team = await choose(
      context,
      tr("Choose a team"),
      teams.map(teamChoice),
      new Error(
        `${tr("Swipt is sideloaded on {device} by more than one team; choose one with --team ID:", { device: device.name })}\n${teamList(teams)}`,
      ),
    );
    return { team, current: found.find((app) => app.team === team) };
  }
  if (found.length === 0 && fresh) {
    const teams = xcodeTeams();
    if (teams.length === 0) {
      throw new Error(
        xcodeSignedIn()
          ? tr(
              "Xcode has no development certificate; add one at {accounts} › Manage Certificates, or choose a team with --team ID",
              { accounts: accountsHint },
            )
          : tr(
              "Xcode has no account; sign in at {accounts}, or choose a team with --team ID",
              { accounts: accountsHint },
            ),
      );
    }
    const team =
      teams.length === 1
        ? teams[0].id
        : await choose(
            context,
            tr("Choose a team"),
            teams.map(teamChoice),
            new Error(
              `${tr("choose a team with --team ID:")}\n${teamList(teams)}`,
            ),
          );
    return { team, current: undefined };
  }
  return { team: found[0]?.team, current: found[0] };
}

const buildText = (app) => `Swipt ${app.version} (${app.bundleVersion})`;

async function signingPeriod(device, id, team) {
  const names = [id, "*"].map((it) => `iOS Team Provisioning Profile: ${it}`);
  const profiles = await step(
    tr("checking Swipt on {device}", { device: device.name }),
    () => provisioningProfiles(device.udid),
    { transient: true },
  );
  return profiles
    .filter(
      (profile) =>
        profile.teamIdentifier === team && names.includes(profile.name),
    )
    .map((profile) => ({
      creation: Date.parse(profile.creationDate),
      expiration: Date.parse(profile.expirationDate),
    }))
    .reduce((latest, it) => (it.expiration > latest.expiration ? it : latest), {
      creation: 0,
      expiration: 0,
    });
}

function expirationText(time) {
  const hours = (time - Date.now()) / 3_600_000;
  const days = Math.round(hours / 24);
  const [value, unit] =
    hours < 24
      ? [Math.max(Math.round(hours), 1), "hour"]
      : days < 7
        ? [days, "day"]
        : days < 30
          ? [Math.round(days / 7), "week"]
          : days < 365
            ? [Math.round(days / 30), "month"]
            : [Math.round(days / 365), "year"];
  return new Intl.RelativeTimeFormat(language)
    .format(value, unit)
    .replace(/(\d)(\p{Script=Han})/gu, "$1 $2");
}

async function askPasscode(context) {
  const type = await select(
    {
      message: tr(
        "Set up auto-unlock? Swipt can then unlock this device by itself",
      ),
      theme: selectTheme,
      choices: [
        {
          name: tr("4 or 6 digit passcode"),
          short: tr("4 or 6 digits"),
          value: "pin",
        },
        {
          name: tr("Custom numeric passcode"),
          short: tr("numeric"),
          value: "numeric",
        },
        {
          name: tr("Custom alphanumeric passcode"),
          short: tr("alphanumeric"),
          value: "alphanumeric",
        },
        { name: tr("No Thanks"), value: null },
      ],
    },
    { output: process.stderr, signal: context.signal },
  );
  if (type === null) {
    return undefined;
  }
  const options = (passcode) => ({ passcode, "passcode-type": type });
  return passcodeOf(
    options(
      await password(
        {
          message: tr("Device passcode"),
          theme: { i18n: { maskedText: tr("[input is masked]") } },
          validate(passcode) {
            try {
              passcodeOf(options(passcode));
              return passcode !== "" || tr("enter the passcode");
            } catch (error) {
              return error.message;
            }
          },
        },
        { output: process.stderr, signal: context.signal },
      ),
    ),
  );
}

async function deploy(context, onlyNewer) {
  const device = await coreDevice(
    context,
    onlyNewer
      ? {
          filter: (devices) =>
            sideloadedDevices(
              devices,
              tr(
                'Swipt is not sideloaded on any online iOS device; install it with "swipt sideload install"',
              ),
            ),
        }
      : undefined,
  );
  const { team, current } = await locate(context, device, !onlyNewer);
  if (current === undefined && onlyNewer) {
    throw new Error(
      team === undefined
        ? tr(
            'Swipt is not sideloaded on {device}; install it with "swipt sideload install"',
            { device: device.name },
          )
        : tr(
            'Swipt is not sideloaded on {device} by team {team}; install it with "swipt sideload install"',
            { device: device.name, team },
          ),
    );
  }
  const passcode =
    current === undefined &&
    interactive(context) &&
    context.options.passcode === undefined &&
    context.options["passcode-type"] === undefined &&
    !context.options["no-setup"]
      ? await askPasscode(context)
      : passcodeOf(context.options);
  const release = await step(
    tr("checking the latest release"),
    () => findRelease(context.options.nightly, context.signal),
    { transient: true },
  );
  const id = `${bundleId}.${team}`;
  if (onlyNewer) {
    const installed = Number(current.bundleVersion);
    const signing = await signingPeriod(device, id, team);
    if (installed >= release.build && !expiresSoon(signing)) {
      console.log(
        installed === release.build
          ? tr(
              "{build} on {device} is already {release}; its signing expires {expiration}",
              {
                build: buildText(current),
                device: device.name,
                release: release.tag,
                expiration: expirationText(signing.expiration),
              },
            )
          : tr(
              "{build} on {device} is newer than {release} ({releaseBuild}); its signing expires {expiration}",
              {
                build: buildText(current),
                device: device.name,
                release: release.tag,
                releaseBuild: release.build,
                expiration: expirationText(signing.expiration),
              },
            ),
      );
      if (
        !context.options["no-setup"] &&
        !context.options["no-setup-pair"] &&
        (await pair(device, id))
      ) {
        await openConfigured(context, device, id, passcode);
      }
      return;
    }
    if (installed > release.build) {
      throw new Error(
        tr(
          '{build} on {device} needs new signing, but {release} ({releaseBuild}) is older; use --nightly, or downgrade with "swipt sideload install"',
          {
            build: buildText(current),
            device: device.name,
            release: release.tag,
            releaseBuild: release.build,
          },
        ),
      );
    }
  }
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "swipt-sideload-"));
  try {
    const signing = await step(
      tr("preparing signing for Swipt with team {team} through Xcode", {
        team: xcodeTeams().find((it) => it.id === team)?.name ?? team,
      }),
      (update) => provision(work, id, team, device, update),
    );
    const ipa = path.join(work, "Swipt.ipa");
    await step(
      tr("downloading Swipt {version} ({build}) from {release}", {
        version: release.version,
        build: release.build,
        release: release.tag,
      }),
      (update) => download(release.ipa, ipa, context.signal, update),
    );
    const app = await step(tr("re-signing Swipt"), async (update) => {
      const unpacked = await unpack(ipa, work);
      await resign(unpacked, id, signing, update);
      return unpacked;
    });
    await step(tr("installing on {device}", { device: device.name }), () =>
      devicectl(["device", "install", "app", "--device", device.udid, app]),
    );
    if (current === undefined && passcode !== undefined) {
      await step(tr("setting up auto-unlock"), () =>
        setUpAutoUnlock(device, id, work, passcode),
      );
    }
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  const result = (await locate({ options: { team } }, device)).current;
  if (result === undefined || Number(result.bundleVersion) !== release.build) {
    throw new Error(
      result === undefined
        ? `${device.name} does not list ${id} after the install`
        : `${device.name} has ${buildText(result)} after the install`,
    );
  }
  const expiration = expirationText(
    (await signingPeriod(device, id, team)).expiration,
  );
  console.log(
    current === undefined
      ? tr(
          "{build} is installed on {device}; its signing expires {expiration}",
          { build: buildText(result), device: device.name, expiration },
        )
      : Number(current.bundleVersion) === release.build
        ? tr(
            "{build} is re-signed on {device}; its signing expires {expiration}",
            { build: buildText(result), device: device.name, expiration },
          )
        : tr(
            "{build} is updated on {device}; its signing expires {expiration}",
            { build: buildText(result), device: device.name, expiration },
          ),
  );
  if (context.options["no-setup"]) {
    await launch(device, id);
    return;
  }
  if (!context.options["no-setup-pair"]) {
    await pair(device, id);
  }
  await openConfigured(context, device, id, passcode);
}

const launchCommand = (device, id, args = []) => [
  "device",
  "process",
  "launch",
  "--terminate-existing",
  "--device",
  device.udid,
  id,
  ...(args.length > 0 ? ["--", ...args] : []),
];

const publishArgument = "--publish-local-network";
const setupArgument = "--setup";

async function openConfigured(context, device, id, passcode) {
  try {
    await trustAndOpen(context, device, id, passcode);
  } catch (error) {
    if (error.message !== serverHint) {
      throw error;
    }
    console.error(
      tr("{hint}; its developer is not trusted automatically", {
        hint: serverHint,
      }),
    );
    await launch(
      device,
      id,
      context.options["no-setup-api"] ? [] : [publishArgument],
    );
  }
}

async function launch(device, id, args) {
  try {
    await step(tr("opening Swipt on {device}", { device: device.name }), () =>
      devicectl(launchCommand(device, id, args)),
    );
  } catch (error) {
    if (/trusted by the user/.test(error.message)) {
      await step(
        tr("opening Settings on {device}", { device: device.name }),
        () =>
          devicectl([
            "device",
            "process",
            "launch",
            "--device",
            device.udid,
            "--payload-url",
            "prefs:root=General&path=ManagedConfigurationList",
            "com.apple.Preferences",
          ]),
      );
      console.log(
        tr(
          "its developer is not trusted yet; trust it in the Settings page opened on {device}, then open Swipt",
          { device: device.name },
        ),
      );
    } else if (/BSErrorCodeDescription = Locked/.test(error.message)) {
      console.log(
        tr("it opens once {device} is unlocked", { device: device.name }),
      );
    } else {
      throw error;
    }
  }
}

export const install = (context) => deploy(context, false);

export const update = (context) => deploy(context, true);

const serverHint = tr(
  'swipt-server is missing; install it with "npm install -g @swipt/cli --include=optional"',
);

const trustMessages = JSON.stringify({
  unlockToContinue: tr("unlock the device to continue"),
  unlocking: tr("unlocking the device"),
  trusting: tr("trusting {developer} in Settings", {
    developer: "{developer}",
  }),
  running: tr("{app} is running", { app: "{app}" }),
  trusted: tr("{developer} is trusted", { developer: "{developer}" }),
});

const deviceNotListedExit = 3;

async function serverPath() {
  const root = path.dirname(import.meta.dirname);
  if (fs.existsSync(path.join(root, "cmd/swipt-server"))) {
    await exec("make", ["server"], { cwd: root });
    return path.join(root, "build/swipt-server");
  }
  let packaged;
  try {
    packaged = path.join(
      path.dirname(
        createRequire(import.meta.url).resolve(
          `@swipt/server-${process.platform}-${process.arch}/package.json`,
        ),
      ),
      "swipt-server",
    );
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") {
      throw error;
    }
    return "swipt-server";
  }
  return fs.existsSync(packaged) ? packaged : "swipt-server";
}

const schema = [
  "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)",
  'CREATE TABLE "preferences" ("name" TEXT PRIMARY KEY NOT NULL, "data" BLOB NOT NULL)',
  'CREATE TABLE "swiplets" ("id" TEXT PRIMARY KEY NOT NULL, "position" INTEGER NOT NULL, "etag" TEXT NOT NULL)',
  'CREATE TABLE "repositories" ("url" TEXT PRIMARY KEY NOT NULL, "position" INTEGER NOT NULL, "name" TEXT NOT NULL, "localizedNames" TEXT, "iconColor" TEXT, "iconSymbol" TEXT, "image" BLOB, "etag" TEXT NOT NULL)',
  'CREATE TABLE "repositorySwiplets" ("repository" TEXT NOT NULL REFERENCES "repositories"("url") ON DELETE CASCADE, "position" INTEGER NOT NULL, "id" TEXT NOT NULL, "name" TEXT NOT NULL, "localizedNames" TEXT NOT NULL, "description" TEXT NOT NULL, "version" TEXT NOT NULL, "versionCode" INTEGER NOT NULL, "iconColor" TEXT, "iconSymbol" TEXT, "url" TEXT NOT NULL, "sha256" TEXT NOT NULL, PRIMARY KEY ("repository", "id"))',
  "INSERT INTO grdb_migrations VALUES ('0.1.0')",
];

async function setUpAutoUnlock(device, id, work, passcode) {
  const database = path.join(work, "Swipt.sqlite");
  const preferences = {
    serverAutoUnlocks: true,
    serverAutoUnlockPasscodeType: passcodeTypes.indexOf(passcode.type),
    serverAutoUnlockPasscode: passcode.passcode,
    autoUnlockSetUp: true,
  };
  const quote = (text) => `'${text.replaceAll("'", "''")}'`;
  execFileSync("sqlite3", [database], {
    input: [
      ...schema,
      ...Object.entries(preferences).map(
        ([name, value]) =>
          `INSERT INTO preferences VALUES (${quote(name)}, CAST(${quote(JSON.stringify(value))} AS BLOB))`,
      ),
    ]
      .map((statement) => `${statement};\n`)
      .join(""),
  });
  await devicectl([
    "device",
    "copy",
    "to",
    "--device",
    device.udid,
    "--source",
    database,
    "--destination",
    "Library/Application Support/Swipt.sqlite",
    "--domain-type",
    "appDataContainer",
    "--domain-identifier",
    id,
  ]);
}

const pairingFile = "PairingRecord.plist";
const pairingPath = `Library/Application Support/${pairingFile}`;

async function hasPairing(device, id) {
  const { result } = await devicectl(
    [
      "device",
      "info",
      "files",
      "--device",
      device.udid,
      "--domain-type",
      "appDataContainer",
      "--domain-identifier",
      id,
    ],
    { parse: true },
  );
  return result.files.some((file) => file.relativePath === pairingPath);
}

async function pair(device, id) {
  const paired = await step(
    tr("checking Swipt on {device}", { device: device.name }),
    () => hasPairing(device, id),
    { transient: true },
  );
  if (paired) {
    return false;
  }
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "swipt-pairing-"));
  let warning;
  try {
    await step(
      tr("pairing with {device}", { device: device.name }),
      async () => {
        const record = path.join(work, pairingFile);
        try {
          await exec(await serverPath(), [
            "pair",
            "-d",
            device.udid,
            "-o",
            record,
          ]);
        } catch (error) {
          if (typeof error.code === "number") {
            warning = tr(
              "pairing failed, so Swipt pairs in Settings instead: {error}",
              { error: error.stderr.trim() },
            );
          } else if (error.code === "ENOENT") {
            warning = tr("{hint}; Swipt pairs in Settings instead", {
              hint: serverHint,
            });
          }
          throw error;
        }
        await devicectl([
          "device",
          "copy",
          "to",
          "--device",
          device.udid,
          "--source",
          record,
          "--destination",
          pairingPath,
          "--domain-type",
          "appDataContainer",
          "--domain-identifier",
          id,
        ]);
      },
    );
  } catch (error) {
    if (warning === undefined) {
      throw error;
    }
    console.error(warning);
    return false;
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
  return true;
}

async function serve(udid, passcode, signal) {
  const server = spawn(
    await serverPath(),
    [
      "-d",
      udid,
      ...(passcode
        ? ["--passcode", passcode.passcode, "--passcode-type", passcode.type]
        : []),
    ],
    {
      stdio: ["ignore", "pipe", "pipe"],
      signal,
    },
  );
  let logs = "";
  server.stderr.on("data", (chunk) => {
    logs += chunk;
  });
  const exited = new Promise((resolve) => server.once("close", resolve));
  const url = new Promise((resolve, reject) => {
    server.once("error", (error) =>
      reject(error.code === "ENOENT" ? new Error(serverHint) : error),
    );
    exited.then((code) =>
      reject(
        Object.assign(
          new Error(
            `swipt-server exited with ${code ?? "a signal"}${logs.trim() === "" ? "" : `: ${logs.trim()}`}`,
          ),
          { exitCode: code },
        ),
      ),
    );
    readline.createInterface({ input: server.stdout }).on("line", (line) => {
      const found = /^Swipt API: (\S+)/.exec(line);
      if (found) {
        const parsed = new URL(found[1]);
        parsed.hostname = "127.0.0.1";
        resolve(parsed.origin);
      }
    });
  });
  return {
    url,
    stop() {
      server.kill("SIGTERM");
      return exited;
    },
  };
}

async function trustAndOpen(context, device, id, passcode) {
  const lines = [];
  let failure;
  try {
    await step(
      tr("opening Swipt on {device}", { device: device.name }),
      async (update) => {
        const unlock =
          passcode !== undefined
            ? "passcode"
            : process.stderr.isTTY
              ? "wait"
              : "";
        let server;
        let url;
        while (url === undefined) {
          server = await serve(device.udid, passcode, context.signal);
          try {
            url = await server.url;
          } catch (error) {
            if (error.exitCode !== deviceNotListedExit || unlock !== "wait") {
              throw error;
            }
            update(tr("waiting for {device}", { device: device.name }));
          }
        }
        try {
          const client = open({ url, token: "" });
          const run = async (args) => {
            for await (const response of client.repl.execute(
              {
                code: fs.readFileSync(
                  new URL("sideload/trust.js", import.meta.url),
                  "utf8",
                ),
                args: [trustMessages, ...args],
                program: true,
              },
              { signal: context.signal },
            )) {
              switch (response.part.case) {
                case "console": {
                  const output = response.part.value;
                  if (output.level === LogLevel.DEBUG) {
                    update(output.text);
                  } else {
                    lines.push(output);
                  }
                  break;
                }
                case "error":
                  failure = response.part.value;
                  break;
              }
            }
            if (failure) {
              throw new Error(failure.message);
            }
          };
          await run([id, "trust", unlock]);
          update("");
          await devicectl(
            launchCommand(device, id, [
              setupArgument,
              ...(context.options["no-setup-api"] ? [] : [publishArgument]),
            ]),
          );
          await run([id, "prompts"]);
        } finally {
          await server.stop();
        }
      },
    );
  } catch (error) {
    if (failure === undefined) {
      throw error;
    }
  } finally {
    for (const output of lines) {
      (output.level === LogLevel.ERROR || output.level === LogLevel.WARN
        ? console.error
        : console.log)(output.text);
    }
  }
  if (failure) {
    if (
      passcode === undefined &&
      failure.name === "UnavailableError" &&
      /\bdevice is locked\b/.test(failure.message)
    ) {
      throw new Error(
        tr(
          "{device}: {message}; unlock it or pass --passcode, then run this again",
          { device: device.name, message: failure.message },
        ),
      );
    }
    throw printScriptError(failure);
  }
}

export async function uninstall(context) {
  const device = await coreDevice(context, { filter: sideloadedDevices });
  const { team, current } = await locate(context, device);
  if (current === undefined) {
    throw new Error(
      team === undefined
        ? tr("Swipt is not sideloaded on {device}", { device: device.name })
        : tr("Swipt is not sideloaded on {device} by team {team}", {
            device: device.name,
            team,
          }),
    );
  }
  await step(tr("removing Swipt from {device}", { device: device.name }), () =>
    devicectl([
      "device",
      "uninstall",
      "app",
      "--device",
      device.udid,
      current.bundleIdentifier,
    ]),
  );
  console.log(
    tr("removed {build} from {device}", {
      build: buildText(current),
      device: device.name,
    }),
  );
}
