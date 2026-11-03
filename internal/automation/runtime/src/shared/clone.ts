export interface CloneInterface {
  readonly type: { readonly prototype: object };
  readonly clone?: (value: never) => object;
  readonly transfer?: (value: never) => readonly [received: object, complete: () => void];
}

export interface StructuredSerializeOptions {
  transfer?: Iterable<object>;
}

const uncurry = <T extends (...args: never[]) => unknown>(method: T) =>
  Function.prototype.call.bind(method) as unknown as (target: unknown, ...args: Parameters<T>) => ReturnType<T>;
const getter = <T>(target: object, name: PropertyKey) => uncurry(Object.getOwnPropertyDescriptor(target, name)!.get as () => T);
const branded = (check: (value: object) => unknown) => (value: object): boolean => {
  try {
    check(value);
    return true;
  } catch {
    return false;
  }
};

const objectTag = uncurry(Object.prototype.toString) as (value: unknown) => string;
const { getPrototypeOf, getOwnPropertyDescriptor, defineProperty, keys } = Object;
const hasOwn = Object.hasOwn;
const isArray = Array.isArray;
const isView = ArrayBuffer.isView;
const isError = (Error as { isError?: (value: unknown) => boolean }).isError ?? ((value: unknown) => value instanceof Error);

const booleanValue = uncurry(Boolean.prototype.valueOf);
const numberValue = uncurry(Number.prototype.valueOf);
const stringValue = uncurry(String.prototype.valueOf);
const bigintValue = uncurry(BigInt.prototype.valueOf);
const dateTime = uncurry(Date.prototype.getTime);
const regExpSource = getter<string>(RegExp.prototype, "source");
const regExpFlags = ([["hasIndices", "d"], ["global", "g"], ["ignoreCase", "i"], ["multiline", "m"], ["dotAll", "s"], ["unicode", "u"], ["unicodeSets", "v"], ["sticky", "y"]] as const)
  .flatMap(([name, flag]) => (getOwnPropertyDescriptor(RegExp.prototype, name)?.get === undefined ? [] : [[getter<boolean>(RegExp.prototype, name), flag] as const]));

interface Buffer extends ArrayBuffer {
  readonly resizable: boolean;
  readonly maxByteLength: number;
  readonly detached: boolean;
  resize(length: number): void;
  transfer(length?: number): ArrayBuffer;
}

const bufferPrototype = ArrayBuffer.prototype as Buffer;
const optionalGetter = <T>(target: object, name: PropertyKey, fallback: (target: unknown) => T) =>
  getOwnPropertyDescriptor(target, name)?.get === undefined ? fallback : getter<T>(target, name);
const bufferLength = getter<number>(bufferPrototype, "byteLength");
const bufferResizable = optionalGetter<boolean>(bufferPrototype, "resizable", () => false);
const bufferMaxLength = optionalGetter<number>(bufferPrototype, "maxByteLength", bufferLength);
const bufferDetached = optionalGetter<boolean>(bufferPrototype, "detached", () => false);
const bufferResize = uncurry(bufferPrototype.resize ?? (() => {}));
const bufferTransfer = uncurry(bufferPrototype.transfer ?? (() => new ArrayBuffer(0)));

type TypedArrayType = (new (buffer: ArrayBuffer, byteOffset: number, length?: number) => object) & { readonly BYTES_PER_ELEMENT: number };
const TypedArray = getPrototypeOf(Uint8Array) as { prototype: { at(index: number): unknown } };
const typedArrayName = getter<string | undefined>(TypedArray.prototype, Symbol.toStringTag);
const typedArrayBuffer = getter<Buffer>(TypedArray.prototype, "buffer");
const typedArrayOffset = getter<number>(TypedArray.prototype, "byteOffset");
const typedArrayLength = getter<number>(TypedArray.prototype, "length");
const typedArrayInBounds = branded(value => uncurry(TypedArray.prototype.at)(value, 0));
const dataViewBuffer = getter<Buffer>(DataView.prototype, "buffer");
const dataViewOffset = getter<number>(DataView.prototype, "byteOffset");
const dataViewLength = getter<number>(DataView.prototype, "byteLength");
const typedArrays = new Map(
  ["Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"]
    .flatMap(name => {
      const type = (globalThis as { [name: string]: unknown })[name];
      return typeof type === "function" ? [[name, type as TypedArrayType] as const] : [];
    }),
);

const mapForEach = uncurry(Map.prototype.forEach as (callback: (value: unknown, key: unknown) => void) => void);
const setForEach = uncurry(Set.prototype.forEach as (callback: (value: unknown) => void) => void);
const mapSet = uncurry(Map.prototype.set as (key: unknown, value: unknown) => Map<unknown, unknown>);
const setAdd = uncurry(Set.prototype.add as (value: unknown) => Set<unknown>);
const isArrayBuffer = branded(bufferLength);

type Builtin = "Boolean" | "Number" | "String" | "BigInt" | "Date" | "RegExp" | "ArrayBuffer" | "Map" | "Set" | "uncloneable";

const builtins: readonly (readonly [tag: string, kind: Builtin, is: (value: object) => boolean])[] = [
  ["Boolean", "Boolean", branded(booleanValue)],
  ["Number", "Number", branded(numberValue)],
  ["String", "String", branded(stringValue)],
  ["BigInt", "BigInt", branded(bigintValue)],
  ["Date", "Date", branded(dateTime)],
  ["RegExp", "RegExp", branded(getter(RegExp.prototype, "global"))],
  ["ArrayBuffer", "ArrayBuffer", isArrayBuffer],
  ["Map", "Map", branded(getter(Map.prototype, "size"))],
  ["Set", "Set", branded(getter(Set.prototype, "size"))],
  ["Symbol", "uncloneable", branded(uncurry(Symbol.prototype.valueOf))],
  ["SharedArrayBuffer", "uncloneable", typeof SharedArrayBuffer === "function" ? branded(getter(SharedArrayBuffer.prototype, "byteLength")) : () => false],
  ["WeakMap", "uncloneable", branded(value => WeakMap.prototype.has.call(value as WeakMap<object, unknown>, {}))],
  ["WeakSet", "uncloneable", branded(value => WeakSet.prototype.has.call(value as WeakSet<object>, {}))],
  ["WeakRef", "uncloneable", branded(value => WeakRef.prototype.deref.call(value as WeakRef<object>))],
  ["FinalizationRegistry", "uncloneable", branded(value => FinalizationRegistry.prototype.unregister.call(value as FinalizationRegistry<unknown>, {}))],
  ["Promise", "uncloneable", value => value instanceof Promise],
];
const hints = new Map(builtins.map(entry => [`[object ${entry[0]}]`, entry]));

const builtinOf = (value: object) => {
  const tag = objectTag(value);
  if (tag === "[object Object]" || tag === "[object Arguments]") {
    return undefined;
  }
  const hinted = hints.get(tag);
  return hinted !== undefined && hinted[2](value) ? hinted : builtins.find(([, , is]) => is(value));
};

const errors: { [name: string]: ErrorConstructor } = { Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError };
const errorExtras = ["stack", "line", "column", "sourceURL"];

const createBuffer = (source: ArrayBuffer): ArrayBuffer => {
  const length = bufferLength(source);
  return bufferResizable(source)
    ? new (ArrayBuffer as new (length: number, options: { maxByteLength: number }) => ArrayBuffer)(length, { maxByteLength: bufferMaxLength(source) })
    : new ArrayBuffer(length);
};

const tracksLength = (buffer: ArrayBuffer, measure: () => number, step: number): boolean => {
  const length = bufferLength(buffer);
  const before = measure();
  if (length + step <= bufferMaxLength(buffer)) {
    bufferResize(buffer, length + step);
    const after = measure();
    bufferResize(buffer, length);
    return after !== before;
  }
  if (before <= 0 || length < step) {
    return false;
  }
  const tail = new Uint8Array(step);
  tail.set(new Uint8Array(buffer, length - step, step));
  bufferResize(buffer, length - step);
  const after = measure();
  bufferResize(buffer, length);
  new Uint8Array(buffer, length - step, step).set(tail);
  return after === before - 1;
};

const transferList = (options: unknown): object[] => {
  if (options === undefined || options === null) {
    return [];
  }
  if (typeof options !== "object" && typeof options !== "function") {
    throw new TypeError("the options are not an object");
  }
  const transfer = (options as StructuredSerializeOptions).transfer;
  if (transfer === undefined) {
    return [];
  }
  if (transfer === null || typeof transfer !== "object" || typeof (transfer as Iterable<unknown>)[Symbol.iterator] !== "function") {
    throw new TypeError("the transfer list is not a sequence");
  }
  return Array.from(transfer as Iterable<unknown>, item => {
    if (item === null || (typeof item !== "object" && typeof item !== "function")) {
      throw new TypeError("the transfer list holds a value that is not an object");
    }
    return item;
  });
};

export function createStructuredClone(DOMException: new (message?: string, name?: string) => Error, interfaces: readonly CloneInterface[]) {
  const prototypes = new Map<object, CloneInterface>(interfaces.map(entry => [entry.type.prototype, entry]));
  const failure = (message: string) => new DOMException(message, "DataCloneError");
  const property = { value: undefined as unknown, writable: true, enumerable: true, configurable: true };

  const interfaceOf = (value: object): CloneInterface | undefined => {
    for (let prototype = getPrototypeOf(value); prototype !== null; prototype = getPrototypeOf(prototype)) {
      const found = prototypes.get(prototype);
      if (found !== undefined) {
        return found;
      }
    }
    return undefined;
  };

  return function structuredClone<T>(value: T, options: StructuredSerializeOptions = {}): T {
    if (arguments.length === 0) {
      throw new TypeError("structuredClone needs a value");
    }
    const memory = new Map<object, object>();
    const transferred = new Map<ArrayBuffer, ArrayBuffer | undefined>();
    const completions: (() => void)[] = [];
    for (const item of transferList(options)) {
      if (memory.has(item) || transferred.has(item as ArrayBuffer)) {
        throw failure(`${objectTag(item)} appears in the transfer list more than once`);
      }
      if (isArrayBuffer(item)) {
        const buffer = item as ArrayBuffer;
        transferred.set(buffer, undefined);
        completions.push(() => {
          if (bufferDetached(buffer)) {
            throw failure("a detached ArrayBuffer could not be transferred");
          }
          const copy = transferred.get(buffer);
          if (copy !== undefined) {
            if (bufferResizable(copy)) {
              bufferResize(copy, bufferLength(buffer));
            }
            new Uint8Array(copy).set(new Uint8Array(buffer));
          }
          bufferTransfer(buffer, 0);
        });
        continue;
      }
      const transfer = interfaceOf(item)?.transfer as ((value: object) => readonly [object, () => void]) | undefined;
      if (transfer === undefined) {
        throw failure(`${objectTag(item)} could not be transferred`);
      }
      const [received, complete] = transfer(item);
      memory.set(item, received);
      completions.push(complete);
    }

    const remember = <O extends object>(value: object, target: O): O => {
      memory.set(value, target);
      return target;
    };

    const cloneBuffer = (buffer: ArrayBuffer): ArrayBuffer => {
      const found = memory.get(buffer) as ArrayBuffer | undefined;
      if (found !== undefined) {
        if (transferred.has(buffer) && bufferResizable(found)) {
          bufferResize(found, bufferLength(buffer));
        }
        return found;
      }
      if (transferred.has(buffer)) {
        const copy = createBuffer(buffer);
        transferred.set(buffer, copy);
        return remember(buffer, copy);
      }
      if (bufferDetached(buffer)) {
        throw failure("a detached ArrayBuffer could not be cloned");
      }
      const copy = createBuffer(buffer);
      new Uint8Array(copy).set(new Uint8Array(buffer));
      return remember(buffer, copy);
    };

    const cloneView = (value: object): object => {
      const name = typedArrayName(value);
      const buffer = name === undefined ? dataViewBuffer(value) : typedArrayBuffer(value);
      if (bufferDetached(buffer)) {
        throw failure("a view of a detached ArrayBuffer could not be cloned");
      }
      const resizable = bufferResizable(buffer);
      if (name === undefined) {
        const measure = () => {
          try {
            return dataViewLength(value);
          } catch {
            return -1;
          }
        };
        const length = measure();
        if (length < 0) {
          throw failure("an out-of-bounds DataView could not be cloned");
        }
        const offset = dataViewOffset(value);
        const tracking = resizable && tracksLength(buffer, measure, 1);
        const copy = cloneBuffer(buffer);
        return remember(value, tracking ? new DataView(copy, offset) : new DataView(copy, offset, length));
      }
      const type = typedArrays.get(name);
      if (type === undefined) {
        throw failure(`${name} could not be cloned`);
      }
      if (resizable && !typedArrayInBounds(value)) {
        throw failure(`an out-of-bounds ${name} could not be cloned`);
      }
      const offset = typedArrayOffset(value);
      const length = typedArrayLength(value);
      const tracking = resizable && tracksLength(buffer, () => (typedArrayInBounds(value) ? typedArrayLength(value) : -1), type.BYTES_PER_ELEMENT);
      const copy = cloneBuffer(buffer);
      return remember(value, tracking ? new type(copy, offset) : new type(copy, offset, length));
    };

    const cloneError = (value: object): object => {
      const name = (value as { name?: unknown }).name;
      const message = getOwnPropertyDescriptor(value, "message");
      const error = remember(value, new errors[typeof name === "string" && hasOwn(errors, name) ? name : "Error"]());
      if (message !== undefined && "value" in message) {
        defineProperty(error, "message", { value: `${message.value}`, writable: true, enumerable: false, configurable: true });
      }
      const cause = getOwnPropertyDescriptor(value, "cause");
      if (cause !== undefined && "value" in cause) {
        defineProperty(error, "cause", { value: clone(cause.value), writable: true, enumerable: false, configurable: true });
      }
      for (const key of errorExtras) {
        const extra = getOwnPropertyDescriptor(value, key);
        if (extra !== undefined && "value" in extra) {
          defineProperty(error, key, { value: extra.value, writable: true, enumerable: false, configurable: true });
        }
      }
      return error;
    };

    const cloneProperties = (value: object, target: object): object => {
      memory.set(value, target);
      const names = keys(value);
      for (let index = 0; index < names.length; index++) {
        const name = names[index];
        if (hasOwn(value, name)) {
          property.value = clone((value as { [key: string]: unknown })[name]);
          defineProperty(target, name, property);
        }
      }
      property.value = undefined;
      return target;
    };

    const cloneObject = (value: object): object => {
      if (isView(value)) {
        return cloneView(value);
      }
      const found = interfaceOf(value);
      if (found !== undefined) {
        if (found.clone === undefined) {
          throw failure(`${objectTag(value)} could not be cloned`);
        }
        return remember(value, (found.clone as (value: object) => object)(value));
      }
      if (isError(value)) {
        return cloneError(value);
      }
      if (isArray(value)) {
        return cloneProperties(value, new Array(getOwnPropertyDescriptor(value, "length")!.value as number));
      }
      const builtin = builtinOf(value);
      switch (builtin?.[1]) {
        case undefined:
          return cloneProperties(value, {});
        case "Boolean":
          return remember(value, Object(booleanValue(value)) as object);
        case "Number":
          return remember(value, Object(numberValue(value)) as object);
        case "String":
          return remember(value, Object(stringValue(value)) as object);
        case "BigInt":
          return remember(value, Object(bigintValue(value)) as object);
        case "Date":
          return remember(value, new Date(dateTime(value)));
        case "RegExp":
          return remember(value, new RegExp(regExpSource(value), regExpFlags.map(([get, flag]) => (get(value) ? flag : "")).join("")));
        case "ArrayBuffer":
          return cloneBuffer(value as ArrayBuffer);
        case "Map": {
          const copied: unknown[] = [];
          mapForEach(value, (item, key) => copied.push(key, item));
          const target = remember(value, new Map());
          for (let index = 0; index < copied.length; index += 2) {
            const key = clone(copied[index]);
            mapSet(target, key, clone(copied[index + 1]));
          }
          return target;
        }
        case "Set": {
          const copied: unknown[] = [];
          setForEach(value, item => copied.push(item));
          const target = remember(value, new Set());
          for (const item of copied) {
            setAdd(target, clone(item));
          }
          return target;
        }
        case "uncloneable":
          throw failure(`${builtin[0]} could not be cloned`);
      }
    };

    const clone = (value: unknown): unknown => {
      switch (typeof value) {
        case "symbol":
          throw failure(`${String(value)} could not be cloned`);
        case "function":
          throw failure(`${value.name ? `the function ${value.name}` : "a function"} could not be cloned`);
        case "object":
          return value === null ? null : (memory.get(value) ?? cloneObject(value));
      }
      return value;
    };

    const result = clone(value) as T;
    for (const complete of completions) {
      complete();
    }
    return result;
  };
}
