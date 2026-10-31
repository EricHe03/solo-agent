const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const values = new Map([...alphabet].map((character, index) => [character, index]));

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

export const decodeBase64 = (text: string): Uint8Array => {
  const clean = text.replace(/[^A-Za-z0-9+/]/g, "");
  const out = new Uint8Array(Math.floor(clean.length * 3 / 4));
  let written = 0;
  for (let index = 0; index < clean.length; index += 4) {
    const chunk = [0, 1, 2, 3].map(offset => values.get(clean[index + offset]) ?? 0);
    const value = (chunk[0] << 18) | (chunk[1] << 12) | (chunk[2] << 6) | chunk[3];
    out[written++] = value >> 16;
    if (index + 2 < clean.length) {
      out[written++] = (value >> 8) & 255;
    }
    if (index + 3 < clean.length) {
      out[written++] = value & 255;
    }
  }
  return out.subarray(0, written);
};
