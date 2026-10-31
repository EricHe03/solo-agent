import { inspect } from "../shared/inspect";
import { framesOf, type Frame } from "./format";

const codes: Record<string, number> = {
  IndexSizeError: 1, HierarchyRequestError: 3, WrongDocumentError: 4, InvalidCharacterError: 5, NoModificationAllowedError: 7,
  NotFoundError: 8, NotSupportedError: 9, InvalidStateError: 11, SyntaxError: 12, InvalidModificationError: 13, NamespaceError: 14,
  InvalidAccessError: 15, TypeMismatchError: 17, SecurityError: 18, NetworkError: 19, AbortError: 20, URLMismatchError: 21,
  QuotaExceededError: 22, TimeoutError: 23, InvalidNodeTypeError: 24, DataCloneError: 25,
};

export class DOMException extends Error {
  readonly code: number;

  constructor(message = "", name = "Error") {
    super(message);
    Object.defineProperty(this, "name", { value: name, configurable: true, writable: true });
    this.code = codes[name] ?? 0;
  }
}

export interface Failure {
  name?: string;
  message?: string;
  stack?: Frame[];
}

export function errorFrom({ name = "Error", message = "" }: Failure): Error {
  switch (name) {
    case "AbortError":
    case "TimeoutError":
    case "UnavailableError":
    case "NotSupportedError":
    case "NotAllowedError":
    case "NotFoundError":
    case "DataError":
      return new DOMException(message, name);
    case "TypeError":
      return new TypeError(message);
    case "RangeError":
      return new RangeError(message);
    case "SyntaxError":
      return new SyntaxError(message);
  }
  const error = new Error(message);
  if (name !== "Error") {
    Object.defineProperty(error, "name", { value: name, configurable: true, writable: true });
  }
  return error;
}

export function failureOf(error: unknown): string {
  try {
    if (error instanceof Error) {
      return JSON.stringify({ name: String(error.name), message: String(error.message), stack: framesOf(error) });
    }
    return JSON.stringify({ name: "Error", message: typeof error === "string" ? error : inspect(error) });
  } catch {
    return JSON.stringify({ name: "Error", message: "the thrown value could not be described" });
  }
}

export const isAbort = (error: unknown): boolean => error instanceof Error && error.name === "AbortError";
