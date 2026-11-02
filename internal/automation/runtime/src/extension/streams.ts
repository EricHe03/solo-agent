import {
  ByteLengthQueuingStrategy, CountQueuingStrategy, ReadableByteStreamController, ReadableStream, ReadableStreamBYOBReader, ReadableStreamBYOBRequest,
  ReadableStreamDefaultController, ReadableStreamDefaultReader, TransformStream, TransformStreamDefaultController, WritableStream,
  WritableStreamDefaultController, WritableStreamDefaultWriter,
} from "web-streams-polyfill";

import { invoke } from "./async";
import { TextDecoder, TextEncoder } from "./encoding";
import { failureOf } from "./errors";
import { native } from "./native";

export {
  ByteLengthQueuingStrategy, CountQueuingStrategy, ReadableByteStreamController, ReadableStream, ReadableStreamBYOBReader, ReadableStreamBYOBRequest,
  ReadableStreamDefaultController, ReadableStreamDefaultReader, TransformStream, TransformStreamDefaultController, WritableStream,
  WritableStreamDefaultController, WritableStreamDefaultWriter,
};

interface NativeSource {
  id: string | null;
  started: boolean;
  controller?: ReadableByteStreamController;
  done(): void;
}

type BufferSource = ArrayBuffer | ArrayBufferView;

const sources = new WeakMap<ReadableStream, NativeSource>();
const disturbed = new WeakSet<ReadableStream>();

export const isDisturbed = (stream: ReadableStream): boolean => stream.locked || disturbed.has(stream);

export const chunkBytes = (chunk: unknown): Uint8Array => {
  if (chunk instanceof Uint8Array) {
    return chunk;
  }
  if (ArrayBuffer.isView(chunk)) {
    return new Uint8Array(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  }
  if (chunk instanceof ArrayBuffer) {
    return new Uint8Array(chunk);
  }
  throw new TypeError("the chunk is not an ArrayBuffer or a view of one");
};

export function nativeReadable(id: string, done: () => void = () => {}): ReadableStream<Uint8Array> {
  const source: NativeSource = { id, started: false, done };
  const finish = () => {
    source.id = null;
    source.done();
  };
  const stream = new ReadableStream({
    type: "bytes",
    start(controller) {
      source.controller = controller;
    },
    async pull(controller) {
      source.started = true;
      disturbed.add(stream);
      const current = source.id;
      if (current === null) {
        return;
      }
      let chunk: Uint8Array | null;
      try {
        chunk = await invoke<Uint8Array | null>("stream.read", [current]);
      } catch (error) {
        if (source.id === current) {
          finish();
          controller.error(error);
        }
        return;
      }
      if (source.id !== current) {
        return;
      }
      if (chunk === null) {
        finish();
        controller.close();
        controller.byobRequest?.respond(0);
        return;
      }
      controller.enqueue(chunk);
    },
    cancel(reason) {
      disturbed.add(stream);
      if (source.id !== null) {
        native.release(source.id, failureOf(reason));
        finish();
      }
    },
  }, { highWaterMark: 0 });
  sources.set(stream, source);
  return stream as ReadableStream<Uint8Array>;
}

export function errorNative(stream: ReadableStream, reason: unknown): void {
  const source = sources.get(stream);
  if (source?.id == null) {
    return;
  }
  native.release(source.id, failureOf(reason));
  source.id = null;
  source.done();
  source.controller?.error(reason);
}

export function takeNative(stream: ReadableStream): string | null {
  const source = sources.get(stream);
  if (source?.id == null || source.started || stream.locked) {
    return null;
  }
  stream.getReader();
  const id = source.id;
  source.id = null;
  return id;
}

export function nativeWritable(id: string, accept: (chunk: unknown) => Uint8Array = chunkBytes): WritableStream<BufferSource> {
  let open = true;
  return new WritableStream<BufferSource>({
    async write(chunk) {
      let bytes: Uint8Array;
      try {
        bytes = accept(chunk);
      } catch (error) {
        open = false;
        native.release(id, failureOf(error));
        throw error;
      }
      if (bytes.length > 0) {
        try {
          await invoke("stream.write", [id, native.put(bytes)]);
        } catch (error) {
          open = false;
          throw error;
        }
      }
    },
    async close() {
      open = false;
      await invoke("stream.close", [id]);
    },
    abort(reason) {
      if (open) {
        open = false;
        native.release(id, failureOf(reason));
      }
    },
  });
}

export async function readAll(stream: ReadableStream): Promise<Uint8Array> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    if (!(value instanceof Uint8Array)) {
      const error = new TypeError("the body stream produced a chunk that is not a Uint8Array");
      await reader.cancel(error);
      throw error;
    }
    chunks.push(value);
    size += value.length;
  }
  if (chunks.length === 1) {
    return chunks[0];
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

export function bytesStream(bytes: Uint8Array): ReadableStream<Uint8Array> {
  const stream: ReadableStream<Uint8Array> = new ReadableStream({
    type: "bytes",
    start(controller) {
      if (bytes.length > 0) {
        controller.enqueue(bytes.slice());
      }
      controller.close();
    },
    cancel() {
      disturbed.add(stream);
    },
  }) as ReadableStream<Uint8Array>;
  return stream;
}

export class TextEncoderStream {
  readonly encoding = "utf-8";
  readonly readable: ReadableStream<Uint8Array>;
  readonly writable: WritableStream<string>;

  constructor() {
    const encoder = new TextEncoder();
    let pending = "";
    const stream = new TransformStream<string, Uint8Array>({
      transform(chunk, controller) {
        let text = pending + String(chunk);
        pending = "";
        const last = text.charCodeAt(text.length - 1);
        if (last >= 0xd800 && last <= 0xdbff) {
          pending = text.slice(-1);
          text = text.slice(0, -1);
        }
        if (text !== "") {
          controller.enqueue(encoder.encode(text));
        }
      },
      flush(controller) {
        if (pending !== "") {
          controller.enqueue(new Uint8Array([0xef, 0xbf, 0xbd]));
        }
      },
    });
    this.readable = stream.readable;
    this.writable = stream.writable;
  }
}

export class TextDecoderStream {
  readonly encoding: string;
  readonly fatal: boolean;
  readonly ignoreBOM: boolean;
  readonly readable: ReadableStream<string>;
  readonly writable: WritableStream<BufferSource>;

  constructor(label = "utf-8", options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
    const decoder = new TextDecoder(label, options);
    this.encoding = decoder.encoding;
    this.fatal = decoder.fatal;
    this.ignoreBOM = decoder.ignoreBOM;
    const stream = new TransformStream<BufferSource, string>({
      transform(chunk, controller) {
        const text = decoder.decode(chunkBytes(chunk), { stream: true });
        if (text !== "") {
          controller.enqueue(text);
        }
      },
      flush(controller) {
        const text = decoder.decode();
        if (text !== "") {
          controller.enqueue(text);
        }
      },
    });
    this.readable = stream.readable;
    this.writable = stream.writable;
  }
}

const compressionFormats = ["gzip", "deflate", "deflate-raw"];

const compressionPair = (format: unknown, mode: "compress" | "decompress") => {
  const name = String(format);
  if (!compressionFormats.includes(name)) {
    throw new TypeError(`the compression format ${JSON.stringify(name)} is not one of ${compressionFormats.join(", ")}`);
  }
  const [writer, reader] = native.compression(name, mode);
  return { readable: nativeReadable(reader), writable: nativeWritable(writer) };
};

export class CompressionStream {
  readonly readable: ReadableStream<Uint8Array>;
  readonly writable: WritableStream<BufferSource>;

  constructor(format: "gzip" | "deflate" | "deflate-raw") {
    ({ readable: this.readable, writable: this.writable } = compressionPair(format, "compress"));
  }
}

export class DecompressionStream {
  readonly readable: ReadableStream<Uint8Array>;
  readonly writable: WritableStream<BufferSource>;

  constructor(format: "gzip" | "deflate" | "deflate-raw") {
    ({ readable: this.readable, writable: this.writable } = compressionPair(format, "decompress"));
  }
}
