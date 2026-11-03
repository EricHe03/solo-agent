import {
  arrayBufferView,
  boolean,
  brand,
  bufferSource,
  defineInterface,
  dictionary,
  domString,
  enforcedUnsignedLong,
  enumeration,
  instance,
  isBufferSource,
  isObject,
  nullable,
  optional,
  sequence,
  type Converter,
} from "../shared/webidl";
import { chunk } from "./chunks";
import { DOMException, QuotaExceededError } from "./errors";
import { native } from "./native";

export type KeyType = "public" | "private" | "secret";
export type KeyFormat = "raw" | "spki" | "pkcs8" | "jwk";
export type KeyUsage =
  | "encrypt"
  | "decrypt"
  | "sign"
  | "verify"
  | "deriveKey"
  | "deriveBits"
  | "wrapKey"
  | "unwrapKey";

export interface Params {
  name: string;
  hash?: Params;
  namedCurve?: string;
  modulusLength?: number;
  publicExponent?: Uint8Array;
  saltLength?: number;
  label?: Uint8Array;
  iv?: Uint8Array;
  counter?: Uint8Array;
  length?: number;
  additionalData?: Uint8Array;
  tagLength?: number;
  salt?: Uint8Array;
  info?: Uint8Array;
  iterations?: number;
  public?: CryptoKey;
}

export interface KeySlots {
  type: KeyType;
  extractable: boolean;
  algorithm: Params;
  usages: KeyUsage[];
  material: string;
}

type Kind = "aes" | "hmac" | "kdf" | "rsa" | "ec" | "okp" | "digest";

interface Algorithm {
  kind: Kind;
  use?: "enc" | "sig";
  secret?: KeyUsage[];
  public?: KeyUsage[];
  private?: KeyUsage[];
}

const cipherUsages: KeyUsage[] = ["encrypt", "decrypt", "wrapKey", "unwrapKey"];
const signature = {
  public: ["verify"],
  private: ["sign"],
} satisfies Partial<Algorithm>;
const agreement = {
  use: "enc",
  public: [],
  private: ["deriveKey", "deriveBits"],
} satisfies Partial<Algorithm>;

export const algorithms: Record<string, Algorithm> = {
  "RSASSA-PKCS1-v1_5": { kind: "rsa", use: "sig", ...signature },
  "RSA-PSS": { kind: "rsa", use: "sig", ...signature },
  "RSA-OAEP": {
    kind: "rsa",
    use: "enc",
    public: ["encrypt", "wrapKey"],
    private: ["decrypt", "unwrapKey"],
  },
  ECDSA: { kind: "ec", use: "sig", ...signature },
  ECDH: { kind: "ec", ...agreement },
  Ed25519: { kind: "okp", use: "sig", ...signature },
  X25519: { kind: "okp", ...agreement },
  "AES-CTR": { kind: "aes", use: "enc", secret: cipherUsages },
  "AES-CBC": { kind: "aes", use: "enc", secret: cipherUsages },
  "AES-GCM": { kind: "aes", use: "enc", secret: cipherUsages },
  "AES-KW": { kind: "aes", use: "enc", secret: ["wrapKey", "unwrapKey"] },
  HMAC: { kind: "hmac", use: "sig", secret: ["sign", "verify"] },
  HKDF: { kind: "kdf", secret: ["deriveKey", "deriveBits"] },
  PBKDF2: { kind: "kdf", secret: ["deriveKey", "deriveBits"] },
  "SHA-1": { kind: "digest" },
  "SHA-256": { kind: "digest" },
  "SHA-384": { kind: "digest" },
  "SHA-512": { kind: "digest" },
};

export const canonicalNames = new Map(
  Object.keys(algorithms).map((name) => [upper(name), name]),
);

export function upper(text: string): string {
  return text.replace(/[a-z]/g, (letter) => letter.toUpperCase());
}

const integerArrays = new Set([
  "Int8Array",
  "Uint8Array",
  "Uint8ClampedArray",
  "Int16Array",
  "Uint16Array",
  "Int32Array",
  "Uint32Array",
  "BigInt64Array",
  "BigUint64Array",
]);

export const constructing = Symbol("constructing");

export let slotsOf: (key: CryptoKey) => KeySlots;
export let isKey: (value: unknown) => value is CryptoKey;
export let createCryptoKey: (slots: KeySlots) => CryptoKey;
let createSubtle: () => SubtleCrypto;
let createCrypto: () => Crypto;

export const CryptoKey = defineInterface(
  class CryptoKey {
    readonly #slots: KeySlots;
    readonly #algorithm: Web.KeyAlgorithm;
    readonly #usages: KeyUsage[];

    static [brand](value: object) {
      return #slots in value;
    }

    static {
      slotsOf = (key) => key.#slots;
      isKey = (value): value is CryptoKey =>
        typeof value === "object" && value !== null && #slots in value;
      createCryptoKey = (slots) => new CryptoKey(constructing, slots);
    }

    constructor(...args: unknown[]) {
      if (args[0] !== constructing) {
        throw new TypeError("Illegal constructor");
      }
      this.#slots = args[1] as KeySlots;
      this.#algorithm = Object.fromEntries(
        Object.entries(this.#slots.algorithm)
          .filter(([, value]) => value !== undefined)
          .map(([member, value]) => [
            member,
            value instanceof Uint8Array
              ? value.slice()
              : member === "hash"
                ? { name: (value as Params).name }
                : value,
          ]),
      ) as Web.KeyAlgorithm;
      this.#usages = [...this.#slots.usages];
    }

    get type(): KeyType {
      return this.#slots.type;
    }

    get extractable(): boolean {
      return this.#slots.extractable;
    }

    get algorithm(): Web.KeyAlgorithm {
      return this.#algorithm;
    }

    get usages(): KeyUsage[] {
      return this.#usages;
    }
  },
  {},
);
export type CryptoKey = InstanceType<typeof CryptoKey>;

export const cloneKey = (key: CryptoKey): CryptoKey => {
  const slots = slotsOf(key);
  return createCryptoKey({ ...slots, usages: [...slots.usages] });
};

const algorithmIdentifier: Converter<object | string> = (value, context) =>
  isObject(value) ? value : domString(value, context);
const cryptoKey = (value: unknown, context: string) =>
  instance(CryptoKey)(value, context);
const keyFormat = enumeration<KeyFormat>(["raw", "spki", "pkcs8", "jwk"]);
const keyUsages = sequence(
  enumeration<KeyUsage>([
    "encrypt",
    "decrypt",
    "sign",
    "verify",
    "deriveKey",
    "deriveBits",
    "wrapKey",
    "unwrapKey",
  ]),
);
const rsaOtherPrimesInfo = dictionary({
  d: domString,
  r: domString,
  t: domString,
});
const jsonWebKey = dictionary({
  alg: domString,
  crv: domString,
  d: domString,
  dp: domString,
  dq: domString,
  e: domString,
  ext: boolean,
  k: domString,
  key_ops: sequence(domString),
  kty: domString,
  n: domString,
  oth: sequence(rsaOtherPrimesInfo),
  p: domString,
  q: domString,
  qi: domString,
  use: domString,
  x: domString,
  y: domString,
});
const keyData: Converter = (value, context) =>
  isBufferSource(value)
    ? bufferSource(value, context)
    : jsonWebKey(value, context);

export const SubtleCrypto = defineInterface(
  class SubtleCrypto {
    readonly #brand = true;

    static [brand](value: object) {
      return #brand in value;
    }

    static {
      createSubtle = () => new SubtleCrypto(constructing);
    }

    constructor(...args: unknown[]) {
      if (args[0] !== constructing) {
        throw new TypeError("Illegal constructor");
      }
    }

    async encrypt(algorithm: unknown, key: CryptoKey, data: unknown) {
      return chunk("subtle").encrypt(algorithm, key, data);
    }

    async decrypt(algorithm: unknown, key: CryptoKey, data: unknown) {
      return chunk("subtle").decrypt(algorithm, key, data);
    }

    async sign(algorithm: unknown, key: CryptoKey, data: unknown) {
      return chunk("subtle").sign(algorithm, key, data);
    }

    async verify(
      algorithm: unknown,
      key: CryptoKey,
      signature: unknown,
      data: unknown,
    ) {
      return chunk("subtle").verify(algorithm, key, signature, data);
    }

    async digest(algorithm: unknown, data: unknown) {
      return chunk("subtle").digest(algorithm, data);
    }

    generateKey(
      algorithm:
        | "Ed25519"
        | { name: "Ed25519" }
        | "X25519"
        | { name: "X25519" }
        | Web.RsaHashedKeyGenParams
        | Web.EcKeyGenParams,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ): Promise<{ publicKey: CryptoKey; privateKey: CryptoKey }>;
    generateKey(
      algorithm: Web.AesKeyGenParams | Web.HmacKeyGenParams | Web.Pbkdf2Params,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ): Promise<CryptoKey>;
    generateKey(
      algorithm: Web.AlgorithmIdentifier,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ): Promise<{ publicKey: CryptoKey; privateKey: CryptoKey } | CryptoKey>;
    async generateKey(
      algorithm: unknown,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ) {
      return chunk("subtle").generateKey(algorithm, extractable, keyUsages);
    }

    async deriveKey(
      algorithm: unknown,
      baseKey: CryptoKey,
      derivedKeyType: unknown,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ) {
      return chunk("subtle").deriveKey(
        algorithm,
        baseKey,
        derivedKeyType,
        extractable,
        keyUsages,
      );
    }

    async deriveBits(
      algorithm: unknown,
      baseKey: CryptoKey,
      length: number | null = null,
    ) {
      return chunk("subtle").deriveBits(algorithm, baseKey, length);
    }

    async importKey(
      format: KeyFormat,
      keyData: unknown,
      algorithm: unknown,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ) {
      return chunk("subtle").importKey(
        format,
        keyData,
        algorithm,
        extractable,
        keyUsages,
      );
    }

    exportKey(format: "jwk", key: CryptoKey): Promise<Web.JsonWebKey>;
    exportKey(
      format: Exclude<KeyFormat, "jwk">,
      key: CryptoKey,
    ): Promise<ArrayBuffer>;
    exportKey(
      format: KeyFormat,
      key: CryptoKey,
    ): Promise<ArrayBuffer | Web.JsonWebKey>;
    async exportKey(format: KeyFormat, key: CryptoKey) {
      return chunk("subtle").exportKey(format, key);
    }

    async wrapKey(
      format: KeyFormat,
      key: CryptoKey,
      wrappingKey: CryptoKey,
      wrapAlgorithm: unknown,
    ) {
      return chunk("subtle").wrapKey(format, key, wrappingKey, wrapAlgorithm);
    }

    async unwrapKey(
      format: KeyFormat,
      wrappedKey: unknown,
      unwrappingKey: CryptoKey,
      unwrapAlgorithm: unknown,
      unwrappedKeyAlgorithm: unknown,
      extractable: boolean,
      keyUsages: Iterable<KeyUsage>,
    ) {
      return chunk("subtle").unwrapKey(
        format,
        wrappedKey,
        unwrappingKey,
        unwrapAlgorithm,
        unwrappedKeyAlgorithm,
        extractable,
        keyUsages,
      );
    }
  },
  {
    operations: {
      encrypt: [algorithmIdentifier, cryptoKey, bufferSource],
      decrypt: [algorithmIdentifier, cryptoKey, bufferSource],
      sign: [algorithmIdentifier, cryptoKey, bufferSource],
      verify: [algorithmIdentifier, cryptoKey, bufferSource, bufferSource],
      digest: [algorithmIdentifier, bufferSource],
      generateKey: [algorithmIdentifier, boolean, keyUsages],
      deriveKey: [
        algorithmIdentifier,
        cryptoKey,
        algorithmIdentifier,
        boolean,
        keyUsages,
      ],
      deriveBits: [
        algorithmIdentifier,
        cryptoKey,
        optional(nullable(enforcedUnsignedLong), null),
      ],
      importKey: [keyFormat, keyData, algorithmIdentifier, boolean, keyUsages],
      exportKey: [keyFormat, cryptoKey],
      wrapKey: [keyFormat, cryptoKey, cryptoKey, algorithmIdentifier],
      unwrapKey: [
        keyFormat,
        bufferSource,
        cryptoKey,
        algorithmIdentifier,
        algorithmIdentifier,
        boolean,
        keyUsages,
      ],
    },
  },
);
export type SubtleCrypto = InstanceType<typeof SubtleCrypto>;

export const Crypto = defineInterface(
  class Crypto {
    readonly #subtle = createSubtle();

    static [brand](value: object) {
      return #subtle in value;
    }

    static {
      createCrypto = () => new Crypto(constructing);
    }

    constructor(...args: unknown[]) {
      if (args[0] !== constructing) {
        throw new TypeError("Illegal constructor");
      }
    }

    get subtle(): SubtleCrypto {
      return this.#subtle;
    }

    getRandomValues<T extends ArrayBufferView | null>(array: T): T {
      if (
        !integerArrays.has(
          (array as { [Symbol.toStringTag]?: string })[Symbol.toStringTag] ??
            "",
        )
      ) {
        throw new DOMException(
          "the array is not an integer typed array",
          "TypeMismatchError",
        );
      }
      const view = array as ArrayBufferView;
      if (view.byteLength > 65536) {
        throw new QuotaExceededError("the array is over 65536 bytes");
      }
      new Uint8Array(view.buffer, view.byteOffset, view.byteLength).set(
        native.random(view.byteLength),
      );
      return array;
    }

    randomUUID(): `${string}-${string}-${string}-${string}-${string}` {
      const bytes = native.random(16);
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      const hex = Array.from(bytes, (byte) =>
        byte.toString(16).padStart(2, "0"),
      ).join("");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }
  },
  {
    operations: { getRandomValues: [arrayBufferView], randomUUID: [] },
  },
);
export type Crypto = InstanceType<typeof Crypto>;

export const crypto = createCrypto();
