import { URL } from "whatwg-url-minimum";

import { decodeBase64 } from "../shared/base64";
import { invoke, listen } from "./async";
import { Blob, blobBytes } from "./blob";
import { bytesOf, TextEncoder } from "./encoding";
import { DOMException } from "./errors";
import { CloseEvent, ErrorEvent, Event, EventTarget, MessageEvent, eventHandlers, trust } from "./events";
import { native } from "./native";

type Message = { type: "open"; socket: string; protocol: string; extensions: string }
  | { type: "message"; text?: string; data?: string }
  | { type: "close"; code: number; reason: string; clean: boolean; error?: string };

const token = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/;

export class WebSocket extends EventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;
  readonly CONNECTING = 0;
  readonly OPEN = 1;
  readonly CLOSING = 2;
  readonly CLOSED = 3;

  readonly url: string;
  declare onopen: ((event: Event) => void) | null;
  declare onmessage: ((event: MessageEvent) => void) | null;
  declare onerror: ((event: Event) => void) | null;
  declare onclose: ((event: CloseEvent) => void) | null;

  #state = 0;
  #protocol = "";
  #extensions = "";
  #buffered = 0;
  #binaryType: "blob" | "arraybuffer" = "blob";
  #socket = "";
  #origin: string;
  #sending: Promise<unknown> = Promise.resolve();
  #stop: () => void;

  constructor(url: string | URL, protocols: string | string[] = []) {
    super();
    let parsed: URL;
    try {
      parsed = new URL(String(url));
    } catch {
      throw new DOMException(`${JSON.stringify(String(url))} is not a valid URL`, "SyntaxError");
    }
    if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      parsed.protocol = parsed.protocol === "http:" ? "ws:" : "wss:";
    }
    if (parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
      throw new DOMException(`a WebSocket URL is ws: or wss:, not ${parsed.protocol}`, "SyntaxError");
    }
    if (parsed.hash !== "" || parsed.href.endsWith("#")) {
      throw new DOMException("a WebSocket URL can't have a fragment", "SyntaxError");
    }
    const list = typeof protocols === "string" ? [protocols] : [...protocols].map(String);
    if (list.some(protocol => !token.test(protocol)) || new Set(list).size !== list.length) {
      throw new DOMException("the protocols are not unique tokens", "SyntaxError");
    }
    this.url = parsed.href;
    this.#origin = parsed.origin;
    this.#stop = listen("websocket", [this.url, list], value => this.#receive(value as Message), error => this.#finish(1006, "", false, error));
  }

  get readyState(): number {
    return this.#state;
  }

  get protocol(): string {
    return this.#protocol;
  }

  get extensions(): string {
    return this.#extensions;
  }

  get bufferedAmount(): number {
    return this.#buffered;
  }

  get binaryType(): "blob" | "arraybuffer" {
    return this.#binaryType;
  }

  set binaryType(value: "blob" | "arraybuffer") {
    if (value === "blob" || value === "arraybuffer") {
      this.#binaryType = value;
    }
  }

  #receive(message: Message): void {
    switch (message.type) {
      case "open":
        this.#socket = message.socket;
        this.#protocol = message.protocol;
        this.#extensions = message.extensions;
        this.#state = WebSocket.OPEN;
        this.dispatchEvent(trust(new Event("open")));
        return;
      case "message": {
        if (this.#state !== WebSocket.OPEN) {
          return;
        }
        let data: unknown = message.text;
        if (message.data !== undefined) {
          const bytes = decodeBase64(message.data);
          data = this.#binaryType === "arraybuffer" ? bytes.slice().buffer : new Blob([bytes]);
        }
        this.dispatchEvent(trust(new MessageEvent("message", { data, origin: this.#origin })));
        return;
      }
      case "close":
        this.#finish(message.code, message.reason, message.clean, message.error === undefined ? undefined : new Error(message.error));
    }
  }

  #finish(code: number, reason: string, clean: boolean, error?: Error): void {
    if (this.#state === WebSocket.CLOSED) {
      return;
    }
    this.#stop();
    this.#state = WebSocket.CLOSED;
    this.#socket = "";
    if (!clean) {
      this.dispatchEvent(trust(new ErrorEvent("error", { message: error?.message ?? "", error })));
    }
    this.dispatchEvent(trust(new CloseEvent("close", { code, reason, wasClean: clean })));
  }

  send(data: string | ArrayBuffer | ArrayBufferView | Blob): void {
    if (this.#state === WebSocket.CONNECTING) {
      throw new DOMException("the WebSocket is still connecting", "InvalidStateError");
    }
    const binary = data instanceof Blob || data instanceof ArrayBuffer || ArrayBuffer.isView(data);
    const text = binary ? "" : String(data);
    const bytes = data instanceof Blob ? blobBytes(data) : binary ? bytesOf(data) : new TextEncoder().encode(text);
    const size = bytes.length;
    this.#buffered += size;
    if (this.#state !== WebSocket.OPEN) {
      return;
    }
    const args = binary ? [this.#socket, native.put(bytes), true] : [this.#socket, text, false];
    this.#sending = this.#sending.then(() => invoke("websocket.send", args)).catch(() => {}).finally(() => {
      this.#buffered -= size;
    });
  }

  close(code?: number, reason?: string): void {
    if (code !== undefined) {
      code = Number(code);
      if (code !== 1000 && !(code >= 3000 && code <= 4999)) {
        throw new DOMException(`the close code ${code} is not 1000 or in 3000 to 4999`, "InvalidAccessError");
      }
    }
    const text = reason === undefined ? "" : String(reason);
    if (new TextEncoder().encode(text).length > 123) {
      throw new DOMException("the close reason is over 123 bytes", "SyntaxError");
    }
    if (this.#state === WebSocket.CLOSING || this.#state === WebSocket.CLOSED) {
      return;
    }
    if (this.#state === WebSocket.CONNECTING) {
      this.#stop();
      this.#state = WebSocket.CLOSING;
      setTimeout(() => this.#finish(1006, "", false, new Error("the WebSocket closed before it connected")), 0);
      return;
    }
    this.#state = WebSocket.CLOSING;
    const socket = this.#socket;
    this.#sending = this.#sending.then(() => invoke("websocket.close", [socket, code ?? 1005, text])).catch(() => {});
  }

  get [Symbol.toStringTag](): string {
    return "WebSocket";
  }
}

eventHandlers(WebSocket, ["open", "message", "error", "close"]);
