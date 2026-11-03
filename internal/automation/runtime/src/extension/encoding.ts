import { bytesOf, textDecoderClass } from "../shared/text";
import { allowSharedUint8Array, brand, defineInterface, optional, usvString } from "../shared/webidl";
import { chunk } from "./chunks";
import { DOMException } from "./errors";
import { native } from "./native";

const nativeSize = 1024;

export const TextEncoder = defineInterface(class TextEncoder {
  readonly #brand = true;

  static [brand](value: object) {
    return #brand in value;
  }

  get encoding(): string {
    return "utf-8";
  }

  encode(text = ""): Uint8Array {
    if (text.length >= nativeSize && native !== undefined) {
      return native.encodeText(text);
    }
    const out = new Uint8Array(text.length * 3);
    return out.slice(0, encodeInto(text, out).written);
  }

  encodeInto(input: string, destination: Uint8Array): { read: number; written: number } {
    return encodeInto(input, destination);
  }
}, {
  construct: [],
  operations: { encode: [optional(usvString, "")], encodeInto: [usvString, allowSharedUint8Array] },
});
export type TextEncoder = InstanceType<typeof TextEncoder>;

function encodeInto(text: string, destination: Uint8Array): { read: number; written: number } {
  const capacity = destination.length;
  let read = 0;
  let written = 0;
  while (read < text.length) {
    let point = text.charCodeAt(read);
    let units = 1;
    if (point >= 0xd800 && point <= 0xdfff) {
      const next = text.charCodeAt(read + 1);
      if (point <= 0xdbff && next >= 0xdc00 && next <= 0xdfff) {
        point = 0x10000 + ((point - 0xd800) << 10) + (next - 0xdc00);
        units = 2;
      } else {
        point = 0xfffd;
      }
    }
    if (point < 0x80) {
      if (written >= capacity) {
        break;
      }
      destination[written++] = point;
    } else if (point < 0x800) {
      if (written + 2 > capacity) {
        break;
      }
      destination[written++] = 0xc0 | (point >> 6);
      destination[written++] = 0x80 | (point & 0x3f);
    } else if (point < 0x10000) {
      if (written + 3 > capacity) {
        break;
      }
      destination[written++] = 0xe0 | (point >> 12);
      destination[written++] = 0x80 | ((point >> 6) & 0x3f);
      destination[written++] = 0x80 | (point & 0x3f);
    } else {
      if (written + 4 > capacity) {
        break;
      }
      destination[written++] = 0xf0 | (point >> 18);
      destination[written++] = 0x80 | ((point >> 12) & 0x3f);
      destination[written++] = 0x80 | ((point >> 6) & 0x3f);
      destination[written++] = 0x80 | (point & 0x3f);
    }
    read += units;
  }
  return { read, written };
}

export const TextDecoder = textDecoderClass(() => chunk("encoding-tables"), (bytes, fatal) => native.decodeText(bytes, fatal ? 1 : 0));
export type TextDecoder = InstanceType<typeof TextDecoder>;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function btoa(text: string): string {
  let out = "";
  for (let index = 0; index < text.length; index += 3) {
    const codes = [text.charCodeAt(index), text.charCodeAt(index + 1), text.charCodeAt(index + 2)];
    for (const code of codes) {
      if (code > 0xff) {
        throw new DOMException("the string has characters outside of Latin1", "InvalidCharacterError");
      }
    }
    const [a, b = NaN, c = NaN] = codes;
    const chunk = (a << 16) | ((b || 0) << 8) | (c || 0);
    out += alphabet[(chunk >> 18) & 63] + alphabet[(chunk >> 12) & 63];
    out += Number.isNaN(b) ? "==" : alphabet[(chunk >> 6) & 63] + (Number.isNaN(c) ? "=" : alphabet[chunk & 63]);
  }
  return out;
}

export function atob(data: string): string {
  let text = data.replace(/[\t\n\f\r ]/g, "");
  if (text.length % 4 === 0) {
    text = text.replace(/==?$/, "");
  }
  if (text.length % 4 === 1 || /[^A-Za-z0-9+/]/.test(text)) {
    throw new DOMException("the string is not correctly encoded", "InvalidCharacterError");
  }
  let out = "";
  let buffer = 0;
  let bits = 0;
  for (const character of text) {
    buffer = (buffer << 6) | alphabet.indexOf(character);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out += String.fromCharCode((buffer >> bits) & 0xff);
    }
  }
  return out;
}

export function base64Bytes(bytes: Uint8Array): string {
  let text = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    text += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  return btoa(text);
}

export function bytesBase64(text: string): Uint8Array {
  const decoded = atob(text);
  const out = new Uint8Array(decoded.length);
  for (let index = 0; index < decoded.length; index++) {
    out[index] = decoded.charCodeAt(index);
  }
  return out;
}

export { bytesOf };
