import {
  brand, bufferSource, defineInterface, dictionary, domString, enumeration, implementsInterface, integer, isBufferSource, optional, sequence, usvString,
} from "../shared/webidl";
import { crypto } from "./crypto";
import { bytesOf, TextDecoder, TextEncoder } from "./encoding";
import { native } from "./native";
import { bytesStream, type ReadableStream, TextDecoderStream } from "./streams";

let blobBytes: (blob: Blob) => Uint8Array;

const mediaType = (text: string): string => (/[^ -~]/.test(text) ? "" : text.toLowerCase());

type BlobPart = ArrayBuffer | ArrayBufferView | object | string;

const blobPart = (value: unknown, context: string): BlobPart => {
  if (isBufferSource(value)) {
    return bufferSource(value, context);
  }
  return implementsInterface(Blob, value) ? value as object : usvString(value, context);
};

const blobPropertyBag = dictionary<{ endings: "transparent" | "native"; type: string }>({
  endings: { convert: enumeration(["transparent", "native"]), fallback: "transparent" }, type: { convert: domString, fallback: "" },
});

export const Blob = defineInterface(class Blob {
  readonly #bytes: Uint8Array;
  #type: string;

  static [brand](value: object) {
    return #bytes in value;
  }

  static {
    blobBytes = blob => blob.#bytes;
  }

  constructor(parts?: Iterable<unknown>, options?: { type?: string; endings?: "transparent" | "native" }) {
    const nativeEndings = options!.endings === "native";
    const chunks = Array.from((parts ?? []) as BlobPart[], part => {
      if (typeof part === "string") {
        return new TextEncoder().encode(nativeEndings ? part.replace(/\r\n?/g, "\n") : part);
      }
      return #bytes in part ? part.#bytes : bytesOf(part);
    });
    const bytes = new Uint8Array(chunks.reduce((sum, chunk) => sum + chunk.length, 0));
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    this.#bytes = bytes;
    this.#type = mediaType(options!.type!);
  }

  get size(): number {
    return this.#bytes.length;
  }

  get type(): string {
    return this.#type;
  }

  slice(start?: number, end?: number, type?: string): Blob {
    const blob = new Blob([this.#bytes.subarray(start, end)], { type: "", endings: "transparent" });
    blob.#type = type === undefined ? "" : mediaType(type);
    return blob;
  }

  stream(): ReadableStream<Uint8Array> {
    return bytesStream(this.#bytes);
  }

  textStream(): ReadableStream<string> {
    return bytesStream(this.#bytes).pipeThrough(new TextDecoderStream());
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
}, {
  construct: [optional(sequence(blobPart)), optional(blobPropertyBag)],
  operations: {
    slice: [optional(integer("long long", "Clamp")), optional(integer("long long", "Clamp")), optional(domString)], stream: [], textStream: [], bytes: [], arrayBuffer: [], text: [],
  },
});
export type Blob = InstanceType<typeof Blob>;

const filePropertyBag = dictionary<{ endings: "transparent" | "native"; type: string; lastModified?: number }>({ lastModified: integer("long long") }, blobPropertyBag);

export const File = defineInterface(class File extends Blob {
  readonly #name: string;
  readonly #lastModified: number;

  static [brand](value: object) {
    return #name in value;
  }

  constructor(bits: Iterable<unknown>, name: string, options?: { type?: string; endings?: "transparent" | "native"; lastModified?: number }) {
    super(bits, options);
    this.#name = name;
    this.#lastModified = options!.lastModified ?? Date.now();
  }

  get name(): string {
    return this.#name;
  }

  get lastModified(): number {
    return this.#lastModified;
  }

  get webkitRelativePath(): string {
    return "";
  }
}, {
  construct: [sequence(blobPart), usvString, optional(filePropertyBag)],
});
export type File = InstanceType<typeof File>;

const objectURLs = new Set<string>();

export function createObjectURL(blob: Blob): string {
  const url = `blob:null/${crypto.randomUUID()}`;
  objectURLs.add(url);
  native.publishObjectURL?.(url, blobBytes(blob));
  return url;
}

export function revokeObjectURL(url: string): void {
  if (objectURLs.delete(url)) {
    native.publishObjectURL?.(url, null);
  }
}
