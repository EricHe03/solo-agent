import { DOMException } from "./errors";
import { native } from "./native";

const nativeSize = 1024;

const incomplete = (bytes: Uint8Array): number => {
  for (let back = 1; back <= 3 && back <= bytes.length; back++) {
    const byte = bytes[bytes.length - back];
    if (byte < 0x80) {
      return bytes.length;
    }
    if (byte >= 0xc0) {
      return (byte >= 0xf0 ? 4 : byte >= 0xe0 ? 3 : 2) > back ? bytes.length - back : bytes.length;
    }
  }
  return bytes.length;
};

export class TextEncoder {
  readonly encoding = "utf-8";

  encode(input = ""): Uint8Array {
    const text = String(input);
    if (text.length >= nativeSize && native !== undefined) {
      return native.encodeText(text);
    }
    const out = new Uint8Array(text.length * 3);
    return out.slice(0, this.encodeInto(text, out).written);
  }

  encodeInto(input: string, destination: Uint8Array): { read: number; written: number } {
    const text = String(input);
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

const bom = [0xef, 0xbb, 0xbf];

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
    const stream = Boolean(options?.stream);
    const incoming = bytesOf(input);
    let bytes = incoming;
    if (this.#pending.length > 0) {
      bytes = new Uint8Array(this.#pending.length + incoming.length);
      bytes.set(this.#pending);
      bytes.set(incoming, this.#pending.length);
    }
    let index = 0;
    if (!this.#started && !this.ignoreBOM) {
      const prefix = Math.min(bytes.length, 3);
      if (stream && prefix < 3 && bytes.subarray(0, prefix).every((byte, position) => byte === bom[position])) {
        this.#pending = bytes.slice();
        return "";
      }
      if (prefix === 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
        index = 3;
      }
    }
    if (bytes.length > 0) {
      this.#started = true;
    }
    if (bytes.length - index >= nativeSize && native !== undefined) {
      const stop = stream ? incomplete(bytes) : bytes.length;
      const text = native.decodeText(bytes.subarray(index, stop), this.fatal ? 1 : 0);
      this.#pending = stream ? bytes.slice(stop) : new Uint8Array(0);
      if (!stream) {
        this.#started = false;
      }
      if (typeof text !== "string") {
        this.#pending = new Uint8Array(0);
        this.#started = false;
        throw new TypeError("the data is not valid UTF-8");
      }
      return text;
    }
    const units = new Uint16Array(bytes.length);
    let count = 0;
    let needed = 0;
    let seen = 0;
    let point = 0;
    let lower = 0x80;
    let upper = 0xbf;
    let sequence = 0;
    const invalid = () => {
      if (this.fatal) {
        this.#pending = new Uint8Array(0);
        this.#started = false;
        throw new TypeError("the data is not valid UTF-8");
      }
      units[count++] = 0xfffd;
    };
    while (index < bytes.length) {
      const byte = bytes[index];
      if (needed === 0) {
        sequence = index;
        index++;
        if (byte < 0x80) {
          units[count++] = byte;
        } else if (byte >= 0xc2 && byte <= 0xdf) {
          needed = 1;
          point = byte & 0x1f;
        } else if (byte >= 0xe0 && byte <= 0xef) {
          lower = byte === 0xe0 ? 0xa0 : 0x80;
          upper = byte === 0xed ? 0x9f : 0xbf;
          needed = 2;
          point = byte & 0x0f;
        } else if (byte >= 0xf0 && byte <= 0xf4) {
          lower = byte === 0xf0 ? 0x90 : 0x80;
          upper = byte === 0xf4 ? 0x8f : 0xbf;
          needed = 3;
          point = byte & 0x07;
        } else {
          invalid();
        }
        continue;
      }
      if (byte < lower || byte > upper) {
        needed = seen = point = 0;
        lower = 0x80;
        upper = 0xbf;
        invalid();
        continue;
      }
      index++;
      lower = 0x80;
      upper = 0xbf;
      point = (point << 6) | (byte & 0x3f);
      if (++seen < needed) {
        continue;
      }
      if (point >= 0x10000) {
        point -= 0x10000;
        units[count++] = 0xd800 + (point >> 10);
        units[count++] = 0xdc00 + (point & 0x3ff);
      } else {
        units[count++] = point;
      }
      needed = seen = point = 0;
    }
    this.#pending = new Uint8Array(0);
    if (needed !== 0) {
      if (stream) {
        this.#pending = bytes.slice(sequence);
      } else {
        invalid();
      }
    }
    if (!stream) {
      this.#started = false;
    }
    let out = "";
    for (let start = 0; start < count; start += 0x2000) {
      out += String.fromCharCode.apply(null, units.subarray(start, Math.min(count, start + 0x2000)) as unknown as number[]);
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
