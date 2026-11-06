import { native } from "./native";

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
