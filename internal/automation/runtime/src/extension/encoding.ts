import { DOMException } from "./errors";

export class TextEncoder {
  readonly encoding = "utf-8";

  encode(input = ""): Uint8Array {
    const text = String(input);
    const out = new Uint8Array(text.length * 3);
    return out.slice(0, this.encodeInto(text, out).written);
  }

  encodeInto(input: string, destination: Uint8Array): { read: number; written: number } {
    let read = 0;
    let written = 0;
    for (const character of String(input)) {
      let point = character.codePointAt(0)!;
      if (point >= 0xd800 && point <= 0xdfff) {
        point = 0xfffd;
      }
      const size = point < 0x80 ? 1 : point < 0x800 ? 2 : point < 0x10000 ? 3 : 4;
      if (written + size > destination.length) {
        break;
      }
      if (size === 1) {
        destination[written++] = point;
      } else if (size === 2) {
        destination[written++] = 0xc0 | (point >> 6);
        destination[written++] = 0x80 | (point & 0x3f);
      } else if (size === 3) {
        destination[written++] = 0xe0 | (point >> 12);
        destination[written++] = 0x80 | ((point >> 6) & 0x3f);
        destination[written++] = 0x80 | (point & 0x3f);
      } else {
        destination[written++] = 0xf0 | (point >> 18);
        destination[written++] = 0x80 | ((point >> 12) & 0x3f);
        destination[written++] = 0x80 | ((point >> 6) & 0x3f);
        destination[written++] = 0x80 | (point & 0x3f);
      }
      read += character.length;
    }
    return { read, written };
  }
}

const bytesOf = (input: unknown): Uint8Array => {
  if (input === undefined) {
    return new Uint8Array(0);
  }
  if (input instanceof Uint8Array) {
    return input;
  }
  if (ArrayBuffer.isView(input)) {
    return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  }
  if (input instanceof ArrayBuffer) {
    return new Uint8Array(input);
  }
  throw new TypeError("the input is not an ArrayBuffer or a view of one");
};

export class TextDecoder {
  readonly encoding = "utf-8";
  readonly fatal: boolean;
  readonly ignoreBOM: boolean;
  #pending = new Uint8Array(0);
  #started = false;

  constructor(label = "utf-8", options: { fatal?: boolean; ignoreBOM?: boolean } = {}) {
    if (!["utf-8", "utf8", "unicode-1-1-utf-8"].includes(String(label).trim().toLowerCase())) {
      throw new RangeError(`the encoding ${JSON.stringify(label)} is not supported; only utf-8 is`);
    }
    this.fatal = Boolean(options.fatal);
    this.ignoreBOM = Boolean(options.ignoreBOM);
  }

  decode(input?: unknown, options: { stream?: boolean } = {}): string {
    const incoming = bytesOf(input);
    const bytes = new Uint8Array(this.#pending.length + incoming.length);
    bytes.set(this.#pending);
    bytes.set(incoming, this.#pending.length);
    let out = "";
    let index = 0;
    if (!this.#started && !this.ignoreBOM && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
      index = 3;
    }
    if (bytes.length > 0) {
      this.#started = true;
    }
    const invalid = () => {
      if (this.fatal) {
        throw new TypeError("the data is not valid UTF-8");
      }
      out += "�";
    };
    while (index < bytes.length) {
      const first = bytes[index];
      const size = first < 0x80 ? 1 : first >= 0xc2 && first < 0xe0 ? 2 : first >= 0xe0 && first < 0xf0 ? 3 : first >= 0xf0 && first < 0xf5 ? 4 : 0;
      if (size === 0) {
        invalid();
        index++;
        continue;
      }
      if (index + size > bytes.length) {
        if (options.stream) {
          break;
        }
        invalid();
        index = bytes.length;
        break;
      }
      let point = size === 1 ? first : first & (0xff >> (size + 1));
      let valid = true;
      for (let offset = 1; offset < size; offset++) {
        const next = bytes[index + offset];
        if ((next & 0xc0) !== 0x80) {
          valid = false;
          break;
        }
        point = (point << 6) | (next & 0x3f);
      }
      const minimum = [0, 0, 0x80, 0x800, 0x10000][size];
      if (!valid || point < minimum || point > 0x10ffff || (point >= 0xd800 && point <= 0xdfff)) {
        invalid();
        index++;
        continue;
      }
      out += String.fromCodePoint(point);
      index += size;
    }
    this.#pending = options.stream ? bytes.slice(index) : new Uint8Array(0);
    if (!options.stream) {
      this.#started = false;
    }
    return out;
  }
}

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export function btoa(data: unknown): string {
  const text = String(data);
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

export function atob(data: unknown): string {
  let text = String(data).replace(/[\t\n\f\r ]/g, "");
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
