import { native } from "./native";

const tags = (): string[] => {
  const list = native.languages.split("\n").filter(Boolean);
  return list.length > 0 ? list : ["en"];
};

const separators = (tag: string) => {
  const parts = new Intl.NumberFormat(tag).formatToParts(1234567.5);
  return {
    decimalSeparator:
      parts.find((part) => part.type === "decimal")?.value ?? ".",
    digitGroupingSeparator:
      parts.find((part) => part.type === "group")?.value ?? ",",
  };
};

export function getLocales() {
  return tags().map((languageTag) => {
    const locale = new Intl.Locale(languageTag);
    const maximized = locale.maximize();
    return {
      languageTag,
      languageCode: locale.language,
      languageScriptCode: maximized.script ?? null,
      scriptCode: locale.script ?? null,
      regionCode: locale.region ?? null,
      languageRegionCode: maximized.region ?? null,
      textDirection: [
        "Arab",
        "Hebr",
        "Thaa",
        "Syrc",
        "Nkoo",
        "Adlm",
        "Rohg",
      ].includes(maximized.script ?? "")
        ? ("rtl" as const)
        : ("ltr" as const),
      ...separators(languageTag),
      measurementSystem: ["US", "LR", "MM"].includes(maximized.region ?? "")
        ? ("us" as const)
        : ("metric" as const),
      currencyCode: null,
      currencySymbol: null,
      temperatureUnit: ["US", "LR", "MM", "BS", "BZ", "KY", "PW"].includes(
        maximized.region ?? "",
      )
        ? ("fahrenheit" as const)
        : ("celsius" as const),
    };
  });
}

export function getCalendars() {
  const options = new Intl.DateTimeFormat(tags()[0]).resolvedOptions();
  return [
    {
      calendar: options.calendar ?? null,
      timeZone: options.timeZone ?? null,
      uses24hourClock:
        new Intl.DateTimeFormat(tags()[0], { hour: "numeric" })
          .resolvedOptions()
          .hourCycle?.startsWith("h2") ?? null,
      firstWeekday: null,
    },
  ];
}

export function preferredLocalizations(
  localizations: readonly string[],
): string[] {
  if (
    !Array.isArray(localizations) ||
    !localizations.every((localization) => typeof localization === "string")
  ) {
    throw new TypeError("the localizations must be an array of strings");
  }
  return native.preferredLocalizations(JSON.stringify(localizations));
}
