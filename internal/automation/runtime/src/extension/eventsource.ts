import { URL } from "whatwg-url-minimum";

import { DOMException } from "./errors";
import { AbortController, Event, EventTarget, MessageEvent, eventHandlers, trust } from "./events";
import { fetch, type Response } from "./fetch";
import { TextDecoderStream } from "./streams";

export class EventSource extends EventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSED = 2;
  readonly CONNECTING = 0;
  readonly OPEN = 1;
  readonly CLOSED = 2;

  readonly url: string;
  readonly withCredentials: boolean;
  declare onopen: ((event: Event) => void) | null;
  declare onmessage: ((event: MessageEvent) => void) | null;
  declare onerror: ((event: Event) => void) | null;

  #state = 0;
  #origin: string;
  #retry = 3000;
  #lastEventId = "";
  #controller = new AbortController();
  #timer: number | undefined;

  constructor(url: string | URL, init: { withCredentials?: boolean } = {}) {
    super();
    let parsed: URL;
    try {
      parsed = new URL(String(url));
    } catch {
      throw new DOMException(`${JSON.stringify(String(url))} is not a valid URL`, "SyntaxError");
    }
    this.url = parsed.href;
    this.#origin = parsed.origin;
    this.withCredentials = Boolean(init?.withCredentials);
    void this.#connect();
  }

  get readyState(): number {
    return this.#state;
  }

  close(): void {
    this.#state = EventSource.CLOSED;
    clearTimeout(this.#timer);
    this.#controller.abort();
  }

  #reconnect(): void {
    if (this.#state === EventSource.CLOSED) {
      return;
    }
    this.#state = EventSource.CONNECTING;
    this.dispatchEvent(trust(new Event("error")));
    if (this.#state !== EventSource.CLOSED) {
      this.#timer = setTimeout(() => void this.#connect(), this.#retry);
    }
  }

  #fail(): void {
    if (this.#state === EventSource.CLOSED) {
      return;
    }
    this.#state = EventSource.CLOSED;
    this.dispatchEvent(trust(new Event("error")));
  }

  async #connect(): Promise<void> {
    const controller = new AbortController();
    this.#controller = controller;
    const headers: Record<string, string> = { accept: "text/event-stream", "cache-control": "no-store" };
    if (this.#lastEventId !== "") {
      headers["last-event-id"] = this.#lastEventId;
    }
    let response: Response;
    try {
      response = await fetch(this.url, { headers, signal: controller.signal });
    } catch {
      if (!controller.signal.aborted) {
        this.#reconnect();
      }
      return;
    }
    if (controller.signal.aborted) {
      return;
    }
    const type = (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    if (response.status !== 200 || type !== "text/event-stream" || response.body === null) {
      await response.body?.cancel();
      this.#fail();
      return;
    }
    this.#state = EventSource.OPEN;
    this.dispatchEvent(trust(new Event("open")));
    let eventType = "";
    let data = "";
    let lastEventId = this.#lastEventId;
    let pending = "";
    let carriage = false;
    const line = (text: string) => {
      if (text === "") {
        this.#lastEventId = lastEventId;
        if (data === "") {
          eventType = "";
          return;
        }
        const event = new MessageEvent(eventType || "message", { data: data.endsWith("\n") ? data.slice(0, -1) : data, origin: this.#origin, lastEventId });
        eventType = "";
        data = "";
        if (this.#state !== EventSource.CLOSED) {
          this.dispatchEvent(trust(event));
        }
        return;
      }
      if (text.startsWith(":")) {
        return;
      }
      const colon = text.indexOf(":");
      const field = colon < 0 ? text : text.slice(0, colon);
      let value = colon < 0 ? "" : text.slice(colon + 1);
      if (value.startsWith(" ")) {
        value = value.slice(1);
      }
      switch (field) {
        case "event":
          eventType = value;
          break;
        case "data":
          data += `${value}\n`;
          break;
        case "id":
          if (!value.includes("\0")) {
            lastEventId = value;
          }
          break;
        case "retry":
          if (/^[0-9]+$/.test(value)) {
            this.#retry = Number(value);
          }
          break;
      }
    };
    const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
    const read = async () => {
      for (;;) {
        const { done, value } = await reader.read();
        if (done || this.#state === EventSource.CLOSED) {
          return;
        }
        let text = value;
        if (carriage && text.startsWith("\n")) {
          text = text.slice(1);
        }
        carriage = text.endsWith("\r");
        const parts = (pending + text).split(/\r\n|\r|\n/);
        pending = parts.pop()!;
        for (const part of parts) {
          line(part);
          if (this.#state === EventSource.CLOSED) {
            return;
          }
        }
      }
    };
    await read().catch(() => {});
    void reader.cancel().catch(() => {});
    if (!controller.signal.aborted) {
      this.#reconnect();
    }
  }

  get [Symbol.toStringTag](): string {
    return "EventSource";
  }
}

eventHandlers(EventSource, ["open", "message", "error"]);
