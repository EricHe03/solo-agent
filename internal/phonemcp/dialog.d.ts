type ChoiceStyle = "default" | "destructive" | "cancel";

type ActionName = "add" | "addData" | "book" | "buy" | "call" | "checkIn" | "continue" | "create" | "do" | "download" | "filter"
  | "find" | "get" | "go" | "log" | "open" | "order" | "pay" | "play" | "playSound" | "post" | "request" | "run" | "search" | "send"
  | "set" | "share" | "start" | "startNavigation" | "toggle" | "turnOff" | "turnOn" | "view";

interface Person {
  name: string;
  handle?: { type: "phoneNumber" | "emailAddress"; value: string };
}

interface Placemark {
  name?: string;
  coordinate?: [latitude: number, longitude: number];
  address?: string;
}

// Dismissing a dialog, or declining requestConfirmation or continueInForeground, ends the run there.
interface Dialog {
  // The options show as buttons; a cancel option comes back like any other.
  requestChoice<T extends string | { title: string; style?: ChoiceStyle }>(options: T[], prompt: string): T;
  requestConfirmation(prompt: string, options?: { actionName?: ActionName | { accept: string; deny: string; destructive?: boolean } }): void;
  // literal turns off autocapitalization, autocorrection and smart punctuation.
  requestValue(type: "text", prompt?: string, options?: { multiline?: boolean; literal?: boolean }): string;
  requestValue(type: "integer", prompt?: string, options?: { stepper?: boolean; min?: number; max?: number }): number;
  requestValue(type: "number", prompt?: string, options?: { min?: number; max?: number }): number;
  requestValue(type: "date" | "time" | "dateTime", prompt?: string): Date;
  // type is a Uniform Type Identifier.
  requestValue(type: "file", prompt?: string): { name: string; type: string; bytes: Uint8Array };
  requestValue(type: "person", prompt?: string): Person;
  requestValue(type: "placemark", prompt?: string): Placemark;
  // The values show as a list.
  requestDisambiguation(values: string[], prompt: string): string;
  // Only the prompt shows, not the value.
  requestValueConfirmation(value: string, prompt: string): boolean;
  continueInForeground(prompt?: string, options?: { alwaysConfirm?: boolean }): void;
}

declare const dialog: Dialog;
