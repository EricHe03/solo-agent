const [id, mode, waitsForUnlock] = args;
const name = "Swipt";
const settings = "com.apple.Preferences";
const springboard = "com.apple.springboard";
const developerPattern =
  /(?:Apple Development|iPhone Developer): .+?\([A-Z0-9]{10}\)/;

const sheet = (timeoutMs) =>
  accessibility.find(
    { app: springboard, role: "sheet", label: /./ },
    { timeoutMs, poll: true },
  );

const inSettings = (selector, timeoutMs) =>
  accessibility.find({ app: settings, ...selector }, { timeoutMs, poll: true });

const escaped = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

async function tap(element) {
  try {
    await accessibility.tap(element, { timeoutMs: 0 });
  } catch (error) {
    if (error.name !== "TimeoutError") {
      throw error;
    }
  }
}

async function dismiss(alert, index) {
  const until = Date.now() + 10_000;
  let absent = 0;
  do {
    const shown = await sheet();
    if (shown === null) {
      absent += 1;
      if (absent === 2) {
        return;
      }
      continue;
    }
    if (shown.label !== alert.label) {
      return;
    }
    absent = 0;
    await tap(shown.findAll({ role: "button" })[index]);
  } while (Date.now() < until);
  throw new Error(`the alert stays: ${alert.label}`);
}

async function answerPrompt() {
  const alert = await sheet();
  const buttons = alert?.findAll({ role: "button" }) ?? [];
  if (alert?.label?.includes(name) && [2, 3].includes(buttons.length)) {
    console.debug("answering a permission alert");
    // The location alert shows an icon and lists Allow Once first; the cellular
    // data alert of China mainland devices shows none and lists Wi-Fi and
    // cellular first (iPhone18,2, iOS 27.2 24B115).
    const location = alert.findAll({ role: "image" }).length > 0;
    await dismiss(alert, buttons.length === 2 || location ? 1 : 0);
  }
  return alert !== null;
}

async function launch() {
  try {
    console.debug(`launching ${name}`);
    await device.launchApplication(id, { restart: true });
    return null;
  } catch (error) {
    const until = Date.now() + 5_000;
    do {
      const alert = await sheet(Math.max(until - Date.now(), 0));
      const buttons = alert?.findAll({ role: "button" }) ?? [];
      if (buttons.length === 1) {
        const developer = alert
          .findAll({ role: "text" })
          .map((text) => developerPattern.exec(text.label ?? "")?.[0])
          .find((found) => found !== undefined);
        await dismiss(alert, 0);
        if (developer === undefined) {
          throw new Error(`the alert names no developer: ${alert.label}`);
        }
        return developer;
      }
    } while (Date.now() < until);
    throw error;
  }
}

function developerRows(list, developer) {
  if (list.findAll({ role: "button", identifier: "VPN" }).length === 0) {
    return [];
  }
  const elsewhere = new Set(
    list
      .findAll({
        role: "button",
        within: {
          identifier: "com.apple.settings.sidebar.collectionView",
        },
      })
      .concat(
        list.findAll({
          role: "button",
          within: { role: /^(navigationBar|searchField)$/ },
        }),
      )
      .map((row) => row.identifier),
  );
  return list
    .findAll({ role: "button" })
    .filter(
      (row) =>
        row.identifier !== undefined &&
        row.identifier !== "BackButton" &&
        row.identifier !== "VPN" &&
        !row.identifier.startsWith("com.apple.settings.") &&
        row.identifier !== row.label &&
        !elsewhere.has(row.identifier),
    )
    .sort(
      (a, b) =>
        developer.includes(b.identifier) - developer.includes(a.identifier),
    );
}

async function openDeviceManagement(developer) {
  await device.launchApplication(settings, {
    url: "prefs:root=General&path=ManagedConfigurationList",
  });
  const until = Date.now() + 10_000;
  do {
    const list = await accessibility.snapshot({ scope: "frontApp" });
    const rows = developerRows(list, developer);
    if (rows.length > 0) {
      return rows;
    }
    await answerPrompt();
  } while (Date.now() < until);
  throw new Error(`Settings lists no app from ${developer}`);
}

async function allowDeveloper(row) {
  const control = {
    role: "text",
    label: new RegExp(
      `.${escaped(row.identifier)}|${escaped(row.identifier)}.`,
    ),
  };
  if ((await inSettings(control, 1_500)) === null) {
    return false;
  }
  const until = Date.now() + 5_000;
  do {
    const shown = await inSettings(control);
    if (shown !== null) {
      await input.tap(shown.point);
    }
    const alert = await sheet();
    const buttons = alert?.findAll({ role: "button" }) ?? [];
    if (buttons.length === 2) {
      await dismiss(alert, 0);
      while (
        (await inSettings(control)) !== null &&
        Date.now() < until + 10_000
      );
      return true;
    }
  } while (Date.now() < until);
  throw new Error("Settings did not ask to allow the developer");
}

async function trust(developer) {
  console.debug(`trusting ${developer} in Settings`);
  const page = { label: new RegExp(escaped(developer)) };
  for (const row of await openDeviceManagement(developer)) {
    const until = Date.now() + 3_000;
    let opened = null;
    do {
      await tap(row);
      opened = await inSettings(page);
    } while (opened === null && Date.now() < until);
    if (opened !== null && (await allowDeveloper(row))) {
      return;
    }
    const button = await inSettings({ identifier: "BackButton" }, 3_000);
    if (button === null) {
      throw new Error("Settings shows no back button");
    }
    await tap(button);
  }
  throw new Error(`Settings lists no app from ${developer}`);
}

async function waitForUnlock() {
  let announced = false;
  for (;;) {
    try {
      if (!(await device.locked.get())) {
        return;
      }
    } catch (error) {
      if (error.name !== "UnavailableError") {
        throw error;
      }
    }
    if (!announced) {
      console.debug("unlock the device to continue");
      announced = true;
    }
  }
}

async function finishSetup() {
  const until = Date.now() + 60_000;
  do {
    if (!(await answerPrompt())) {
      const finished = await accessibility.find({
        app: id,
        identifier: "setup-finished",
      });
      if (finished !== null) {
        console.log(`${name} is running`);
        return;
      }
    }
  } while (Date.now() < until);
  throw new Error(`${name} did not finish setting up`);
}

async function main() {
  if (mode === "prompts") {
    await finishSetup();
    return;
  }
  console.debug("unlocking the device");
  await device.unlock().catch(() => {});
  if (waitsForUnlock === "wait") {
    await waitForUnlock();
  }
  await answerPrompt();
  const developer = await launch();
  if (developer !== null) {
    await trust(developer);
    console.log(`${developer} is trusted`);
  }
}

await main();
