export type Converter<T = unknown> = (value: unknown, context: string) => T;

interface Argument {
  readonly convert: Converter;
  readonly optional?: true;
  readonly variadic?: true;
  readonly fallback?: { readonly value: unknown };
}

interface Signature {
  readonly length: number;
  convert(args: readonly unknown[], context: string): unknown[];
}

export type Arguments = readonly (Converter | Argument)[] | Signature;

type Method = (this: unknown, ...args: never[]) => unknown;
type Pairs = readonly (readonly [unknown, unknown])[];

export interface Definition<T extends object = object> {
  readonly construct?: Arguments;
  readonly operations?: Readonly<Record<string, Arguments>>;
  readonly statics?: Readonly<Record<string, Arguments>>;
  readonly setters?: Readonly<Record<string, Converter>>;
  readonly constants?: Readonly<Record<string, number>>;
  readonly events?: readonly string[];
  readonly unforgeable?: readonly string[];
  readonly include?: readonly object[];
  readonly iterable?: (value: T) => Pairs;
}

export const brand: unique symbol = Symbol("brand");

const {
  apply,
  construct: reflectConstruct,
  defineProperty,
  deleteProperty,
  getOwnPropertyDescriptor,
  getPrototypeOf,
  ownKeys,
  setPrototypeOf,
} = Reflect;
const { create, defineProperties } = Object;
const PromiseConstructor = Promise;
const { reject } = Promise;

export const isObject = (value: unknown): value is object =>
  (typeof value === "object" && value !== null) || typeof value === "function";

const fail = (message: string): never => {
  throw new TypeError(message);
};

export const any: Converter<unknown> = (value) => value;

export const boolean: Converter<boolean> = (value) => !!value;

export const domString: Converter<string> = (value, context) =>
  typeof value === "symbol"
    ? fail(`${context} is a symbol, not a string`)
    : `${value as string}`;

export const usvString: Converter<string> = (value, context) =>
  domString(value, context).toWellFormed();

export const double: Converter<number> = (value, context) => {
  const number = +(value as number);
  return Number.isFinite(number)
    ? number
    : fail(`${context} is not a finite number`);
};

const integerBits = {
  byte: [8, true],
  octet: [8, false],
  short: [16, true],
  "unsigned short": [16, false],
  long: [32, true],
  "unsigned long": [32, false],
  "long long": [64, true],
  "unsigned long long": [64, false],
} as const;

export const integer = (
  type: keyof typeof integerBits,
  attribute?: "EnforceRange" | "Clamp",
): Converter<number> => {
  const [bits, signed] = integerBits[type];
  const upper =
    bits === 64
      ? Number.MAX_SAFE_INTEGER
      : signed
        ? 2 ** (bits - 1) - 1
        : 2 ** bits - 1;
  const lower =
    bits === 64
      ? signed
        ? Number.MIN_SAFE_INTEGER
        : 0
      : signed
        ? -(2 ** (bits - 1))
        : 0;
  return (value, context) => {
    let number = +(value as number);
    if (attribute === "EnforceRange") {
      if (!Number.isFinite(number)) {
        fail(`${context} is not a finite number`);
      }
      number = Math.trunc(number);
      return number < lower || number > upper
        ? fail(`${context} is outside ${lower} to ${upper}`)
        : number + 0;
    }
    if (attribute === "Clamp" && !Number.isNaN(number)) {
      number = Math.min(Math.max(number, lower), upper);
      const floor = Math.floor(number);
      const fraction = number - floor;
      return (
        (fraction < 0.5 || (fraction === 0.5 && floor % 2 === 0)
          ? floor
          : floor + 1) + 0
      );
    }
    if (!Number.isFinite(number) || number === 0) {
      return 0;
    }
    number = Math.trunc(number);
    if (bits === 64) {
      return Number(
        signed
          ? BigInt.asIntN(64, BigInt(number))
          : BigInt.asUintN(64, BigInt(number)),
      );
    }
    number -= Math.floor(number / 2 ** bits) * 2 ** bits;
    return signed && number >= 2 ** (bits - 1) ? number - 2 ** bits : number;
  };
};

export const octet = integer("octet");
export const unsignedShort = integer("unsigned short");
export const long = integer("long");
export const unsignedLong = integer("unsigned long");
export const enforcedOctet = integer("octet", "EnforceRange");
export const enforcedUnsignedShort = integer("unsigned short", "EnforceRange");
export const enforcedUnsignedLong = integer("unsigned long", "EnforceRange");

export const object: Converter<object> = (value, context) =>
  isObject(value) ? value : fail(`${context} is not an object`);

export const callbackFunction: Converter<(...args: never[]) => unknown> = (
  value,
  context,
) =>
  typeof value === "function"
    ? (value as (...args: never[]) => unknown)
    : fail(`${context} is not a function`);

export const callbackInterface: Converter<object> = (value, context) =>
  isObject(value) ? value : fail(`${context} is not an object`);

export type BufferSource = ArrayBuffer | ArrayBufferView;
export type AllowSharedBufferSource = ArrayBufferLike | ArrayBufferView;

const getterOf = <T>(
  target: object,
  key: PropertyKey,
): ((value: unknown) => T) => {
  const get = getOwnPropertyDescriptor(target, key)?.get;
  return get === undefined
    ? () => undefined as T
    : (value) => apply(get, value, []) as T;
};
const branded =
  (getter: (value: unknown) => unknown) =>
  (value: unknown): boolean => {
    try {
      getter(value);
      return true;
    } catch {
      return false;
    }
  };
const typedArrayPrototype = getPrototypeOf(Uint8Array.prototype) as object;
const typedArrayName = getterOf<string | undefined>(
  typedArrayPrototype,
  Symbol.toStringTag,
);
const typedArrayBuffer = getterOf<ArrayBufferLike>(
  typedArrayPrototype,
  "buffer",
);
const dataViewBuffer = getterOf<ArrayBufferLike>(DataView.prototype, "buffer");
const isArrayBuffer = branded(getterOf(ArrayBuffer.prototype, "byteLength"));
const resizable = getterOf<boolean | undefined>(
  ArrayBuffer.prototype,
  "resizable",
);
const shared =
  typeof SharedArrayBuffer === "function"
    ? SharedArrayBuffer.prototype
    : undefined;
const isSharedArrayBuffer =
  shared === undefined ? () => false : branded(getterOf(shared, "byteLength"));
const growable =
  shared === undefined
    ? () => false
    : getterOf<boolean | undefined>(shared, "growable");

const viewOf =
  (allowShared: boolean, type?: string) =>
  (value: unknown, context: string): ArrayBufferView | undefined => {
    if (!ArrayBuffer.isView(value)) {
      return undefined;
    }
    const name = typedArrayName(value);
    if (type !== undefined && name !== type) {
      fail(`${context} is not a ${type}`);
    }
    const buffer =
      name === undefined ? dataViewBuffer(value) : typedArrayBuffer(value);
    if (
      isSharedArrayBuffer(buffer)
        ? !allowShared || growable(buffer)
        : resizable(buffer)
    ) {
      fail(
        `${context} is backed by a ${isSharedArrayBuffer(buffer) ? "SharedArrayBuffer" : "resizable ArrayBuffer"}`,
      );
    }
    return value;
  };

const bufferOf = (allowShared: boolean): Converter<AllowSharedBufferSource> => {
  const view = viewOf(allowShared);
  return (value, context) => {
    const found = view(value, context);
    if (found !== undefined) {
      return found;
    }
    if (isArrayBuffer(value)) {
      return resizable(value)
        ? fail(`${context} is a resizable ArrayBuffer`)
        : (value as ArrayBuffer);
    }
    if (isSharedArrayBuffer(value)) {
      return !allowShared || growable(value)
        ? fail(`${context} is a SharedArrayBuffer`)
        : (value as ArrayBufferLike);
    }
    return fail(`${context} is not an ArrayBuffer or a view of one`);
  };
};

export const bufferSource = bufferOf(false) as Converter<BufferSource>;
export const allowSharedBufferSource = bufferOf(true);
export const isBufferSource = (value: unknown): boolean =>
  ArrayBuffer.isView(value) || isArrayBuffer(value);

export const arrayBufferView: Converter<ArrayBufferView> = (value, context) =>
  viewOf(false)(value, context) ??
  fail(`${context} is not an ArrayBuffer view`);

export const allowSharedUint8Array: Converter<Uint8Array> = (value, context) =>
  (viewOf(true, "Uint8Array")(value, context) ??
    fail(`${context} is not a Uint8Array`)) as Uint8Array;

export const nullable =
  <T>(convert: Converter<T>): Converter<T | null> =>
  (value, context) =>
    value === undefined || value === null ? null : convert(value, context);

const iteratorMethod = (value: unknown): unknown => {
  const method = (value as { [Symbol.iterator]?: unknown })[Symbol.iterator];
  return method === null ? undefined : method;
};

export const iterableMethod = (value: object, context: string): unknown => {
  const method = iteratorMethod(value);
  return method === undefined || typeof method === "function"
    ? method
    : fail(`${context}'s Symbol.iterator is not a function`);
};

export const sequenceFrom = <T>(
  value: object,
  method: unknown,
  convert: Converter<T>,
  context: string,
): T[] => {
  const iterator: unknown = apply(method as Method, value, []);
  if (!isObject(iterator)) {
    fail(`${context}'s iterator is not an object`);
  }
  const next = (iterator as { next: unknown }).next;
  const out: T[] = [];
  for (;;) {
    const result: unknown = apply(next as Method, iterator, []);
    if (!isObject(result)) {
      fail(`${context}'s iterator result is not an object`);
    }
    if ((result as IteratorResult<unknown>).done) {
      return out;
    }
    out.push(
      convert(
        (result as IteratorResult<unknown>).value,
        `${context}[${out.length}]`,
      ),
    );
  }
};

export const sequence =
  <T>(convert: Converter<T>): Converter<T[]> =>
  (value, context) => {
    if (!isObject(value)) {
      fail(`${context} is not a sequence`);
    }
    const method = iterableMethod(value as object, context);
    return method === undefined
      ? fail(`${context} is not iterable`)
      : sequenceFrom(value as object, method, convert, context);
  };

export const record =
  <K extends string, V>(
    key: Converter<K>,
    convert: Converter<V>,
  ): Converter<[K, V][]> =>
  (value, context) => {
    if (!isObject(value)) {
      fail(`${context} is not a record`);
    }
    const out: [K, V][] = [];
    for (const name of ownKeys(value as object)) {
      const descriptor = getOwnPropertyDescriptor(value as object, name);
      if (descriptor === undefined || !descriptor.enumerable) {
        continue;
      }
      const typed = key(name, `${context}'s key`);
      const item = convert(
        (value as Record<PropertyKey, unknown>)[name],
        `${context}[${JSON.stringify(typed)}]`,
      );
      const found = out.findIndex(([existing]) => existing === typed);
      if (found < 0) {
        out.push([typed, item]);
      } else {
        out[found][1] = item;
      }
    }
    return out;
  };

const enumerations = new WeakMap<Converter, readonly string[]>();

export const enumeration = <T extends string>(
  values: readonly T[],
): Converter<T> => {
  const convert: Converter<T> = (value, context) => {
    const text = domString(value, context);
    return values.includes(text as T)
      ? (text as T)
      : fail(
          `${context} ${JSON.stringify(text)} is not one of ${values.map((item) => JSON.stringify(item)).join(", ")}`,
        );
  };
  enumerations.set(convert, values);
  return convert;
};

type Member =
  | Converter
  | {
      readonly convert: Converter;
      readonly fallback?: unknown;
      readonly required?: true;
    };

interface MemberEntry {
  readonly key: string;
  readonly convert: Converter;
  readonly fallback?: { readonly value: unknown };
  readonly required: boolean;
}

const dictionaryMembers = new WeakMap<Converter, readonly MemberEntry[]>();
const acceptsUndefined = new WeakSet<Converter>();

export const dictionaryLike = <T>(convert: Converter<T>): Converter<T> => {
  acceptsUndefined.add(convert);
  return convert;
};

export const dictionary = <T extends object>(
  members: Readonly<Record<string, Member>>,
  parent?: Converter,
): Converter<T> => {
  const own = Object.keys(members)
    .sort()
    .map((key): MemberEntry => {
      const member = members[key];
      return typeof member === "function"
        ? { key, convert: member, required: false }
        : {
            key,
            convert: member.convert,
            fallback:
              "fallback" in member ? { value: member.fallback } : undefined,
            required: member.required === true,
          };
    });
  const entries = [
    ...(parent === undefined ? [] : (dictionaryMembers.get(parent) ?? [])),
    ...own,
  ];
  const convert: Converter<T> = (value, context) => {
    if (value !== undefined && value !== null && !isObject(value)) {
      fail(`${context} is not a dictionary`);
    }
    const out = create(null) as Record<string, unknown>;
    for (const { key, convert: member, fallback, required } of entries) {
      const item =
        value === undefined || value === null
          ? undefined
          : (value as Record<string, unknown>)[key];
      if (item !== undefined) {
        out[key] = member(item, `${context}'s ${key}`);
      } else if (fallback !== undefined) {
        out[key] = fallback.value;
      } else if (required) {
        fail(`${context} needs ${key}`);
      }
    }
    return out as T;
  };
  dictionaryMembers.set(convert, entries);
  return dictionaryLike(convert);
};

export const optional = (
  convert: Converter,
  ...fallback: [] | [unknown]
): Argument =>
  fallback.length === 0
    ? { convert, optional: true }
    : { convert, optional: true, fallback: { value: fallback[0] } };

export const variadic = (convert: Converter): Argument => ({
  convert,
  variadic: true,
});

export const overloaded = (
  length: number,
  convert: (args: readonly unknown[], context: string) => unknown[],
): Signature => ({ length, convert });

const compile = (signature: Arguments): Signature => {
  if (!Array.isArray(signature)) {
    return signature as Signature;
  }
  const items = (signature as readonly (Converter | Argument)[]).map((item) =>
    typeof item === "function" ? ({ convert: item } as Argument) : item,
  );
  const required = items.findIndex((item) => item.optional || item.variadic);
  const length = required < 0 ? items.length : required;
  return {
    length,
    convert(args, context) {
      if (args.length < length) {
        fail(
          `${context} needs ${length} argument${length === 1 ? "" : "s"}, but ${args.length} ${args.length === 1 ? "was" : "were"} passed`,
        );
      }
      const out: unknown[] = [];
      for (let index = 0; index < items.length; index++) {
        const { convert, optional, variadic, fallback } = items[index];
        if (variadic) {
          for (let rest = index; rest < args.length; rest++) {
            out.push(convert(args[rest], `${context} argument ${rest + 1}`));
          }
          break;
        }
        const value = args[index];
        if (optional && value === undefined) {
          out.push(
            fallback !== undefined
              ? fallback.value
              : acceptsUndefined.has(convert)
                ? convert(undefined, `${context} argument ${index + 1}`)
                : undefined,
          );
        } else {
          out.push(convert(value, `${context} argument ${index + 1}`));
        }
      }
      return out;
    },
  };
};

interface InterfaceRecord {
  readonly name: string;
  readonly check: (value: unknown) => boolean;
  readonly pairs?: (value: never) => Pairs;
  readonly type: Constructor;
  readonly unforgeable: readonly (readonly [string, PropertyDescriptor])[];
}

const interfaces = new WeakMap<object, InterfaceRecord>();

export const implementsInterface = (
  type: { readonly prototype: object },
  value: unknown,
): boolean => {
  const found = interfaces.get(type.prototype);
  return found !== undefined && found.check(value);
};

export const iterablePairs = (
  type: { readonly prototype: object },
  value: object,
): Pairs =>
  (interfaces.get(type.prototype)!.pairs as (value: object) => Pairs)(value);

export const instance =
  <T>(type: { readonly prototype: T }): Converter<T> =>
  (value, context) => {
    const found = interfaces.get(type.prototype as object);
    return found !== undefined && found.check(value)
      ? (value as T)
      : fail(`${context} is not ${article(found?.name ?? "platform object")}`);
  };

const article = (name: string) =>
  `${/^[AEIOU]/.test(name) ? "an" : "a"} ${name}`;

const illegal = (where: string, name: string) =>
  new TypeError(`${where} can only be called on ${article(name)}`);

const asyncFunctionPrototype = getPrototypeOf(async () => {}) as object;

const operation = (
  key: string,
  method: Method,
  signature: Signature,
  where: string,
  check: ((value: unknown) => boolean) | undefined,
  name: string,
): Method => {
  const { convert } = signature;
  const wrapped =
    getPrototypeOf(method) === asyncFunctionPrototype
      ? {
          operation(this: unknown, ...args: unknown[]) {
            try {
              if (check !== undefined && !check(this)) {
                throw illegal(where, name);
              }
              return apply(method, this, convert(args, where));
            } catch (error) {
              return apply(reject, PromiseConstructor, [error]);
            }
          },
        }.operation
      : {
          operation(this: unknown, ...args: unknown[]) {
            if (check !== undefined && !check(this)) {
              throw illegal(where, name);
            }
            return apply(method, this, convert(args, where));
          },
        }.operation;
  defineProperty(wrapped, "length", { value: signature.length });
  defineProperty(wrapped, "name", { value: key });
  return wrapped as Method;
};

const accessor = (
  key: string,
  descriptor: PropertyDescriptor,
  setter: Converter | undefined,
  where: string,
  check: ((value: unknown) => boolean) | undefined,
  name: string,
): PropertyDescriptor => {
  const { get, set } = descriptor;
  const values = setter === undefined ? undefined : enumerations.get(setter);
  const getter =
    get === undefined
      ? undefined
      : getOwnPropertyDescriptor(
          {
            get attribute() {
              if (check !== undefined && !check(this)) {
                throw illegal(where, name);
              }
              return apply(get, this, []);
            },
          },
          "attribute",
        )!.get!;
  const assign =
    set === undefined
      ? undefined
      : getOwnPropertyDescriptor(
          {
            set attribute(value: unknown) {
              if (arguments.length === 0) {
                fail(`${where} needs a value`);
              }
              if (check !== undefined && !check(this)) {
                throw illegal(where, name);
              }
              if (values !== undefined) {
                const text = domString(value, where);
                if (values.includes(text)) {
                  apply(set, this, [text]);
                }
                return;
              }
              apply(set, this, [setter!(value, where)]);
            },
          },
          "attribute",
        )!.set!;
  if (getter !== undefined) {
    defineProperty(getter, "name", { value: `get ${key}` });
  }
  if (assign !== undefined) {
    defineProperty(assign, "name", { value: `set ${key}` });
  }
  return { get: getter, set: assign, enumerable: true, configurable: true };
};

const install = (
  target: object,
  source: object,
  name: string,
  prefix: string,
  signatures: Readonly<Record<string, Arguments>>,
  setters: Readonly<Record<string, Converter>>,
  check: ((value: unknown) => boolean) | undefined,
  skip: readonly PropertyKey[],
) => {
  for (const key of ownKeys(source)) {
    if (skip.includes(key)) {
      continue;
    }
    const descriptor = getOwnPropertyDescriptor(source, key)!;
    if (typeof key === "symbol") {
      if (key !== Symbol.toStringTag) {
        throw new Error(
          `${name} has the member ${String(key)}, which has no WebIDL shape`,
        );
      }
      continue;
    }
    const where = `${prefix}${key}`;
    if (descriptor.get !== undefined || descriptor.set !== undefined) {
      if (descriptor.set !== undefined && !Object.hasOwn(setters, key)) {
        throw new Error(`${where} has a setter without a converter`);
      }
      defineProperty(
        target,
        key,
        accessor(key, descriptor, setters[key], where, check, name),
      );
    } else if (typeof descriptor.value === "function") {
      if (!Object.hasOwn(signatures, key)) {
        throw new Error(`${where} has no signature`);
      }
      defineProperty(target, key, {
        value: operation(
          key,
          descriptor.value as Method,
          compile(signatures[key]),
          where,
          check,
          name,
        ),
        writable: true,
        enumerable: true,
        configurable: true,
      });
    } else {
      throw new Error(
        `${where} is a data property, which WebIDL has no shape for`,
      );
    }
  }
};

const constant = (value: number): PropertyDescriptor => ({
  value,
  writable: false,
  enumerable: true,
  configurable: false,
});

let eventHandlerHooks:
  | {
      get(target: object, type: string): unknown;
      set(target: object, type: string, value: unknown): void;
    }
  | undefined;

export const setEventHandlerHooks = (hooks: typeof eventHandlerHooks): void => {
  eventHandlerHooks = hooks;
};

const eventHandler: Converter = (value) => (isObject(value) ? value : null);

const iteratorPrototype = getPrototypeOf(
  getPrototypeOf([][Symbol.iterator]()) as object,
) as object;

type Kind = "key" | "value" | "key+value";

const pairIterable = <T extends object>(
  prototype: object,
  name: string,
  check: (value: unknown) => boolean,
  pairsOf: (value: T) => Pairs,
) => {
  const states = new WeakMap<
    object,
    { target: T; kind: Kind; index: number }
  >();
  const iterator = create(iteratorPrototype, {
    next: {
      value: {
        next(this: unknown) {
          const state = isObject(this) ? states.get(this) : undefined;
          if (state === undefined) {
            throw illegal(`${name} Iterator.next`, `${name} Iterator`);
          }
          const pairs = pairsOf(state.target);
          if (state.index >= pairs.length) {
            return { value: undefined, done: true };
          }
          const [key, value] = pairs[state.index++];
          return {
            value:
              state.kind === "key"
                ? key
                : state.kind === "value"
                  ? value
                  : [key, value],
            done: false,
          };
        },
      }.next,
      writable: true,
      enumerable: true,
      configurable: true,
    },
    [Symbol.toStringTag]: { value: `${name} Iterator`, configurable: true },
  }) as object;
  const iterate = (target: unknown, kind: Kind, where: string) => {
    if (!check(target)) {
      throw illegal(where, name);
    }
    const created: object = create(iterator);
    states.set(created, { target: target as T, kind, index: 0 });
    return created;
  };
  const methods = {
    entries(this: unknown) {
      return iterate(this, "key+value", `${name}.entries`);
    },
    keys(this: unknown) {
      return iterate(this, "key", `${name}.keys`);
    },
    values(this: unknown) {
      return iterate(this, "value", `${name}.values`);
    },
    forEach(this: unknown, callback: unknown) {
      if (!check(this)) {
        throw illegal(`${name}.forEach`, name);
      }
      callbackFunction(callback, `${name}.forEach argument 1`);
      const thisArg: unknown = arguments[1];
      let pairs = pairsOf(this as T);
      for (let index = 0; index < pairs.length; index++) {
        const [key, value] = pairs[index];
        apply(callback as Method, thisArg, [value, key, this] as never[]);
        pairs = pairsOf(this as T);
      }
    },
  };
  for (const [key, value] of Object.entries(methods)) {
    defineProperty(prototype, key, {
      value,
      writable: true,
      enumerable: true,
      configurable: true,
    });
  }
  defineProperty(prototype, Symbol.iterator, {
    value: methods.entries,
    writable: true,
    enumerable: false,
    configurable: true,
  });
};

type Constructor = abstract new (...args: never[]) => object;

export function defineInterface<C extends Constructor>(
  type: C,
  definition: Definition<InstanceType<C>>,
): C {
  const { name } = type;
  const check = (type as unknown as { [brand]?: (value: object) => boolean })[
    brand
  ];
  if (typeof check !== "function") {
    throw new Error(`${name} has no brand`);
  }
  deleteProperty(type, brand);
  const isInstance = (value: unknown) => isObject(value) && check(value);
  const prototype = type.prototype as object;
  const parent = getPrototypeOf(type) as object;
  const inherited = interfaces.get(
    (parent as { prototype?: object }).prototype ?? {},
  );
  const signature =
    definition.construct === undefined
      ? undefined
      : compile(definition.construct);
  const unforgeable: (readonly [string, PropertyDescriptor])[] = [
    ...(inherited?.unforgeable ?? []),
  ];
  const created = {
    [name]: function (this: unknown, ...args: unknown[]) {
      if (signature === undefined) {
        fail("Illegal constructor");
      }
      if (new.target === undefined) {
        fail(`${name} must be called with new`);
      }
      const object = reflectConstruct(
        type,
        signature!.convert(args, name),
        new.target,
      ) as object;
      for (let index = 0; index < unforgeable.length; index++) {
        defineProperty(object, unforgeable[index][0], unforgeable[index][1]);
      }
      return object;
    },
  }[name] as unknown as C;
  if (inherited !== undefined) {
    setPrototypeOf(type, inherited.type);
  }
  setPrototypeOf(
    created,
    inherited === undefined ? Function.prototype : parent,
  );
  defineProperties(created, {
    length: { value: signature?.length ?? 0 },
    prototype: {
      value: prototype,
      writable: false,
      enumerable: false,
      configurable: false,
    },
  });
  defineProperty(prototype, "constructor", {
    value: created,
    writable: true,
    enumerable: false,
    configurable: true,
  });

  for (const included of definition.include ?? []) {
    for (const key of ownKeys(included)) {
      if (key !== "constructor") {
        defineProperty(
          prototype,
          key,
          getOwnPropertyDescriptor(included, key)!,
        );
      }
    }
  }
  install(
    prototype,
    prototype,
    name,
    `${name}.`,
    definition.operations ?? {},
    definition.setters ?? {},
    isInstance,
    ["constructor"],
  );
  install(
    created,
    type,
    name,
    `${name}.`,
    definition.statics ?? {},
    {},
    undefined,
    ["length", "name", "prototype"],
  );
  for (const type of definition.events ?? []) {
    const key = `on${type}`;
    defineProperty(
      prototype,
      key,
      accessor(
        key,
        {
          get(this: object) {
            return eventHandlerHooks!.get(this, type);
          },
          set(this: object, value: unknown) {
            eventHandlerHooks!.set(this, type, value);
          },
        },
        eventHandler,
        `${name}.${key}`,
        isInstance,
        name,
      ),
    );
  }
  for (const key of definition.unforgeable ?? []) {
    const descriptor = getOwnPropertyDescriptor(prototype, key)!;
    deleteProperty(prototype, key);
    unforgeable.push([
      key,
      {
        __proto__: null,
        get: descriptor.get,
        set: descriptor.set,
        enumerable: true,
        configurable: false,
      } as PropertyDescriptor,
    ]);
  }
  for (const [key, value] of Object.entries(definition.constants ?? {})) {
    defineProperty(created, key, constant(value));
    defineProperty(prototype, key, constant(value));
  }
  if (definition.iterable !== undefined) {
    pairIterable(prototype, name, isInstance, definition.iterable);
  }
  defineProperty(prototype, Symbol.toStringTag, {
    value: name,
    writable: false,
    enumerable: false,
    configurable: true,
  });
  interfaces.set(prototype, {
    name,
    check: isInstance,
    pairs: definition.iterable,
    type,
    unforgeable,
  });
  return created;
}

interface GlobalDefinition {
  readonly interfaces: Readonly<Record<string, unknown>>;
  readonly operations: Readonly<Record<string, readonly [Method, Arguments]>>;
  readonly attributes: Readonly<
    Record<string, { readonly value: unknown; readonly replaceable?: true }>
  >;
  readonly namespaces: Readonly<Record<string, object>>;
}

export function defineGlobals(
  target: object,
  definition: GlobalDefinition,
): void {
  const isGlobal = (value: unknown) =>
    value === undefined || value === null || value === target;
  for (const [key, value] of Object.entries({
    ...definition.interfaces,
    ...definition.namespaces,
  })) {
    defineProperty(target, key, {
      value,
      writable: true,
      enumerable: false,
      configurable: true,
    });
  }
  for (const [key, [method, signature]] of Object.entries(
    definition.operations,
  )) {
    defineProperty(target, key, {
      value: operation(
        key,
        method,
        compile(signature),
        key,
        isGlobal,
        "global object",
      ),
      writable: true,
      enumerable: true,
      configurable: true,
    });
  }
  for (const [key, { value, replaceable }] of Object.entries(
    definition.attributes,
  )) {
    defineProperty(
      target,
      key,
      accessor(
        key,
        {
          get: () => value,
          set: replaceable
            ? (replaced: unknown) => {
                defineProperty(target, key, {
                  value: replaced,
                  writable: true,
                  enumerable: true,
                  configurable: true,
                });
              }
            : undefined,
        },
        replaceable ? any : undefined,
        key,
        isGlobal,
        "global object",
      ),
    );
  }
}

export function defineNamespace(
  target: object,
  name: string,
  operations: Readonly<Record<string, Arguments>>,
): void {
  install(target, target, name, `${name}.`, operations, {}, undefined, []);
  defineProperty(target, Symbol.toStringTag, {
    value: name,
    writable: false,
    enumerable: false,
    configurable: true,
  });
}
