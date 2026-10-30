import { bytesOf } from "./encoding";
import { DOMException } from "./errors";
import { native } from "./native";

const digests: Record<string, string> = { "SHA-1": "SHA-1", "SHA-256": "SHA-256", "SHA-384": "SHA-384", "SHA-512": "SHA-512" };

export const crypto = Object.freeze({
  getRandomValues<T extends ArrayBufferView | null>(array: T): T {
    if (!ArrayBuffer.isView(array) || array instanceof Float32Array || array instanceof Float64Array || array instanceof DataView) {
      throw new DOMException("the array is not an integer typed array", "TypeMismatchError");
    }
    if (array.byteLength > 65536) {
      throw new DOMException("the array is over 65536 bytes", "QuotaExceededError");
    }
    new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(native.random(array.byteLength));
    return array;
  },
  randomUUID(): string {
    const bytes = native.random(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  },
  subtle: Object.freeze({
    async digest(algorithm: string | { name: string }, data: unknown): Promise<ArrayBuffer> {
      const name = digests[(typeof algorithm === "string" ? algorithm : algorithm?.name ?? "").toUpperCase()];
      if (name === undefined) {
        throw new DOMException(`the digest ${JSON.stringify(algorithm)} is not supported; the digests are ${Object.keys(digests).join(", ")}`, "NotSupportedError");
      }
      const out = native.digest(name, bytesOf(data));
      return out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength) as ArrayBuffer;
    },
  }),
});
