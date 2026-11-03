import { any, brand, defineInterface, implementsInterface, instance, optional, overloaded, usvString } from "../shared/webidl";
import { Blob, File } from "./blob";

type Value = string | File;

const entryArguments = overloaded(2, (args, context) => {
  if (args.length < 2) {
    throw new TypeError(`${context} needs 2 arguments, but ${args.length} ${args.length === 1 ? "was" : "were"} passed`);
  }
  const name = usvString(args[0], `${context} argument 1`);
  if (args.length === 2 && !implementsInterface(Blob, args[1])) {
    return [name, usvString(args[1], `${context} argument 2`)];
  }
  const value = instance(Blob)(args[1], `${context} argument 2`);
  return [name, value, args[2] === undefined ? undefined : usvString(args[2], `${context} argument 3`)];
});

const entryOf = (name: string, value: string | Blob, filename: string | undefined): [string, Value] => {
  if (typeof value === "string") {
    return [name, value];
  }
  if (implementsInterface(File, value) && filename === undefined) {
    return [name, value as File];
  }
  const options = { type: value.type, lastModified: implementsInterface(File, value) ? (value as File).lastModified : undefined };
  return [name, new File([value], filename ?? "blob", options)];
};

let entryList: (form: object) => [string, Value][];

export const FormData = defineInterface(class FormData {
  #entries: [string, Value][] = [];
  declare forEach: (callback: (value: Value, name: string, form: FormData) => void, thisArg?: unknown) => void;
  declare entries: () => Web.FormDataIterator<[string, Value]>;
  declare keys: () => Web.FormDataIterator<string>;
  declare values: () => Web.FormDataIterator<Value>;
  declare [Symbol.iterator]: () => Web.FormDataIterator<[string, Value]>;

  static [brand](value: object) {
    return #entries in value;
  }

  static {
    entryList = form => (form as FormData).#entries;
  }

  constructor(form?: unknown) {
    if (form !== undefined) {
      throw new TypeError("FormData can't read a form element");
    }
  }

  append(name: string, value: string): void;
  append(name: string, blobValue: globalThis.Blob, filename?: string): void;
  append(name: string, value: string | globalThis.Blob, filename?: string): void {
    this.#entries.push(entryOf(name, value as string | Blob, filename));
  }

  set(name: string, value: string): void;
  set(name: string, blobValue: globalThis.Blob, filename?: string): void;
  set(name: string, value: string | globalThis.Blob, filename?: string): void {
    const entries = this.#entries;
    const entry = entryOf(name, value as string | Blob, filename);
    const index = entries.findIndex(([key]) => key === entry[0]);
    if (index < 0) {
      entries.push(entry);
      return;
    }
    entries[index] = entry;
    this.#entries = entries.filter(([key], position) => position <= index || key !== entry[0]);
  }

  get(name: string): Value | null {
    return this.#entries.find(([item]) => item === name)?.[1] ?? null;
  }

  getAll(name: string): Value[] {
    return this.#entries.filter(([item]) => item === name).map(([, value]) => value);
  }

  has(name: string): boolean {
    return this.#entries.some(([item]) => item === name);
  }

  delete(name: string): void {
    this.#entries = this.#entries.filter(([item]) => item !== name);
  }
}, {
  construct: [optional(any)],
  operations: {
    append: entryArguments, set: entryArguments, get: [usvString], getAll: [usvString], has: [usvString], delete: [usvString],
  },
  iterable: form => entryList(form),
});
export type FormData = InstanceType<typeof FormData>;
