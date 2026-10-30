import { base64Bytes, bytesBase64, TextDecoder, TextEncoder } from "./encoding";
import { native } from "./native";

interface Stat {
  kind: "file" | "directory" | "";
  size: number;
  modified: number;
}

export const pathOf = (uri: string): string => {
  if (uri.startsWith("file://")) {
    return decodeURIComponent(uri.slice("file://".length));
  }
  if (uri.startsWith("/")) {
    return uri;
  }
  throw new TypeError(`${JSON.stringify(uri)} is not a file: URI or an absolute path`);
};

const uriOf = (path: string): string => `file://${encodeURI(path).replace(/[?#]/g, encodeURIComponent)}`;

const join = (...parts: string[]): string => {
  const segments: string[] = [];
  for (const part of parts.join("/").split("/")) {
    if (part === "" || part === ".") {
      continue;
    }
    if (part === "..") {
      segments.pop();
    } else {
      segments.push(part);
    }
  }
  return `/${segments.join("/")}`;
};

type Location = string | File | Directory;

const resolve = (uris: Location[]): string => {
  if (uris.length === 0) {
    throw new TypeError("expected a file: URI");
  }
  const [first, ...rest] = uris.map(item => typeof item === "string" ? item : item.uri);
  return join(pathOf(first), ...rest.map(item => item.startsWith("file://") ? pathOf(item) : item));
};

const stat = (path: string): Stat => JSON.parse(native.file("stat", path) as string);

abstract class Entry {
  readonly #path: string;

  constructor(...uris: Location[]) {
    this.#path = resolve(uris);
  }

  protected get path(): string {
    return this.#path;
  }

  get uri(): string {
    return uriOf(this.#path) + (this instanceof Directory ? "/" : "");
  }

  get name(): string {
    return this.#path.split("/").at(-1) ?? "";
  }

  get parentDirectory(): Directory {
    return new Directory(uriOf(join(this.#path, "..")));
  }

  delete(): void {
    native.file("remove", this.#path);
  }

  copy(destination: File | Directory): void {
    native.file("copy", this.#path, destination instanceof Directory ? join(pathOf(destination.uri), this.name) : pathOf(destination.uri));
  }

  move(destination: File | Directory): void {
    native.file("move", this.#path, destination instanceof Directory ? join(pathOf(destination.uri), this.name) : pathOf(destination.uri));
  }
}

export class File extends Entry {
  get exists(): boolean {
    return stat(this.path).kind === "file";
  }

  get size(): number | null {
    const info = stat(this.path);
    return info.kind === "file" ? info.size : null;
  }

  get modificationTime(): number | null {
    const info = stat(this.path);
    return info.kind === "file" ? info.modified : null;
  }

  get extension(): string {
    const dot = this.name.lastIndexOf(".");
    return dot > 0 ? this.name.slice(dot) : "";
  }

  create(): void {
    if (!this.exists) {
      this.write(new Uint8Array(0));
    }
  }

  write(content: string | Uint8Array): void {
    native.file("write", this.path, typeof content === "string" ? new TextEncoder().encode(content) : content);
  }

  bytesSync(): Uint8Array {
    return native.file("read", this.path) as Uint8Array;
  }

  textSync(): string {
    return new TextDecoder().decode(this.bytesSync());
  }

  base64Sync(): string {
    return base64Bytes(this.bytesSync());
  }

  async bytes(): Promise<Uint8Array> {
    return this.bytesSync();
  }

  async text(): Promise<string> {
    return this.textSync();
  }

  async base64(): Promise<string> {
    return this.base64Sync();
  }

  static fromBase64(text: string): Uint8Array {
    return bytesBase64(text);
  }
}

export class Directory extends Entry {
  get exists(): boolean {
    return stat(this.path).kind === "directory";
  }

  create(options: { intermediates?: boolean; idempotent?: boolean } = {}): void {
    if (options.idempotent && this.exists) {
      return;
    }
    native.file("mkdir", this.path, Boolean(options.intermediates));
  }

  createFile(name: string): File {
    const file = new File(this, name);
    file.create();
    return file;
  }

  createDirectory(name: string): Directory {
    const directory = new Directory(this, name);
    directory.create();
    return directory;
  }

  list(): (File | Directory)[] {
    const entries: { name: string; directory: boolean }[] = JSON.parse(native.file("list", this.path) as string);
    return entries.map(entry => entry.directory ? new Directory(this, entry.name) : new File(this, entry.name));
  }
}

export const Paths = Object.freeze({
  get document(): Directory {
    return new Directory(native.documentDirectory);
  },
  get cache(): Directory {
    return new Directory(native.cacheDirectory);
  },
  join: (...uris: Location[]): string => uriOf(resolve(uris)),
  dirname: (uri: Location): string => uriOf(join(resolve([uri]), "..")),
  basename: (uri: Location, extension?: string): string => {
    const name = resolve([uri]).split("/").at(-1) ?? "";
    return extension && name.endsWith(extension) ? name.slice(0, -extension.length) : name;
  },
  extname: (uri: Location): string => {
    const name = resolve([uri]).split("/").at(-1) ?? "";
    const dot = name.lastIndexOf(".");
    return dot > 0 ? name.slice(dot) : "";
  },
});

export const dataDirectory = (): Directory => new Directory(native.dataDirectory);
