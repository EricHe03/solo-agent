export interface Locale {
  languageTag: string;
  languageCode: string | null;
  languageScriptCode: string | null;
  scriptCode: string | null;
  regionCode: string | null;
  languageRegionCode: string | null;
  textDirection: "ltr" | "rtl" | null;
  decimalSeparator: string | null;
  digitGroupingSeparator: string | null;
  measurementSystem: "metric" | "us" | "uk" | null;
  currencyCode: string | null;
  currencySymbol: string | null;
  temperatureUnit: "celsius" | "fahrenheit" | null;
}

export interface Calendar {
  calendar: string | null;
  timeZone: string | null;
  uses24hourClock: boolean | null;
  firstWeekday: number | null;
}

export declare function getLocales(): Locale[];
export declare function getCalendars(): Calendar[];
