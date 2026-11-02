import { crypto } from "./crypto";
import { bytesOf, TextDecoder, TextEncoder } from "./encoding";
import { bytesStream, type ReadableStream } from "./streams";

let blobBytes: (blob: Blob) => Uint8Array;

const mediaType = (type: unknown): string => {
  const text = String(type ?? "");
  return /[^ -~]/.test(text) ? "" : text.toLowerCase();
};

export class Blob {
  readonly #bytes: Uint8Array;
  readonly #type: string;

  static {
    blobBytes = blob => blob.#bytes;
  }

  constructor(parts: Iterable<unknown> = [], options: { type?: string; endings?: "transparent" | "native" } = {}) {
    if (parts === null || typeof parts !== "object" || !(Symbol.iterator in parts)) {
      throw new TypeError("the blob parts are not a sequence");
    }
    if (options?.endings !== undefined && options.endings !== "transparent" && options.endings !== "native") {
      throw new TypeError(`the endings ${JSON.stringify(options.endings)} is not transparent or native`);
    }
    const chunks = Array.from(parts, part => part instanceof Blob ? part.#bytes : typeof part === "string" ? new TextEncoder().encode(part) : ArrayBuffer.isView(part) || part instanceof ArrayBuffer ? bytesOf(part) : new TextEncoder().encode(String(part)));
    const bytes = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    this.#bytes = bytes;
    this.#type = mediaType(options?.type);
  }

  get size(): number {
    return this.#bytes.length;
  }

  get type(): string {
    return this.#type;
  }

  slice(start?: number, end?: number, type?: string): Blob {
    return new Blob([this.#bytes.subarray(start, end)], { type: type ?? "" });
  }

  stream(): ReadableStream<Uint8Array> {
    return bytesStream(this.#bytes);
  }

  async bytes(): Promise<Uint8Array> {
    return this.#bytes.slice();
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this.#bytes.slice().buffer as ArrayBuffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.#bytes);
  }

  get [Symbol.toStringTag](): string {
    return "Blob";
  }
}

export class File extends Blob {
  readonly name: string;
  readonly lastModified: number;
  readonly webkitRelativePath = "";

  constructor(bits: Iterable<unknown>, name: string, options: { type?: string; lastModified?: number } = {}) {
    if (arguments.length < 2) {
      throw new TypeError("File needs its bits and a name");
    }
    super(bits, options);
    this.name = String(name);
    this.lastModified = options?.lastModified === undefined ? Date.now() : Number(options.lastModified);
  }

  get [Symbol.toStringTag](): string {
    return "File";
  }
}

export { blobBytes };

const objectURLs = new Map<string, Blob>();

export function createObjectURL(blob: Blob): string {
  if (!(blob instanceof Blob)) {
    throw new TypeError("createObjectURL takes a Blob");
  }
  const url = `blob:null/${crypto.randomUUID()}`;
  objectURLs.set(url, blob);
  return url;
}

export function revokeObjectURL(url: string): void {
  objectURLs.delete(String(url));
}

export const objectURL = (url: string): Blob | undefined => objectURLs.get(url.replace(/#.*$/s, ""));
