const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

export const encodeBase64 = (bytes: Uint8Array): string => {
  let out = "";
  for (let index = 0; index < bytes.length; index += 3) {
    const first = bytes[index];
    const second = bytes[index + 1];
    const third = bytes[index + 2];
    const chunk = (first << 16) | ((second ?? 0) << 8) | (third ?? 0);
    out += alphabet[chunk >> 18] + alphabet[(chunk >> 12) & 63];
    out += second === undefined ? "=" : alphabet[(chunk >> 6) & 63];
    out += third === undefined ? "=" : alphabet[chunk & 63];
  }
  return out;
};

const lookup = new Uint8Array(128).fill(255);
for (let index = 0; index < alphabet.length; index++) {
  lookup[alphabet.charCodeAt(index)] = index;
}

export const decodeBase64 = (text: string): Uint8Array => {
  const out = new Uint8Array(Math.floor(text.length * 3 / 4) + 3);
  let written = 0;
  let buffer = 0;
  let bits = 0;
  for (let index = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    const value = code < 128 ? lookup[code] : 255;
    if (value === 255) {
      continue;
    }
    buffer = ((buffer << 6) | value) & 0xffffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[written++] = (buffer >> bits) & 255;
    }
  }
  return out.subarray(0, written);
};
