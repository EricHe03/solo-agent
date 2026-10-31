import { decodeBase64, encodeBase64 } from "../shared/base64";
import { fileURI, joinRelative, nameOf } from "../shared/paths";

export interface FileHost {
  fileStat(swiplet: string, path: string): Promise<{ exists: boolean; directory: boolean; size: number; modified: number }>;
  fileList(swiplet: string, path: string): Promise<{ name: string; directory: boolean }[]>;
  fileRead(swiplet: string, path: string): Promise<string>;
  fileReadText(swiplet: string, path: string): Promise<string>;
  fileWrite(swiplet: string, path: string, base64: string): Promise<void>;
  fileWriteText(swiplet: string, path: string, text: string): Promise<void>;
  fileMkdir(swiplet: string, path: string): Promise<void>;
  fileRemove(swiplet: string, path: string): Promise<void>;
  fileCopy(swiplet: string, from: string, to: string): Promise<void>;
  fileMove(swiplet: string, from: string, to: string): Promise<void>;
}

interface Location {
  readonly host: FileHost;
  readonly swiplet: string;
  readonly root: string;
  readonly path: string;
}

const token = Symbol("location");
const locations = new WeakMap<FileHandle | DirectoryHandle, Location>();

const at = (handle: FileHandle | DirectoryHandle): Location => locations.get(handle)!;

const child = (parent: Location, path: string): Location => ({ ...parent, path: joinRelative(parent.path, path) });

const guard = (key: symbol) => {
  if (key !== token) {
    throw new TypeError("file handles come from dataDirectory");
  }
};

export class DirectoryHandle {
  constructor(key: symbol, location: Location) {
    guard(key);
    locations.set(this, location);
    Object.freeze(this);
  }

  get uri(): string {
    const { root, path } = at(this);
    return fileURI(root, path, true);
  }

  get name(): string {
    const { root, path } = at(this);
    return path === "" ? nameOf(decodeURIComponent(root.replace(/\/+$/, ""))) : nameOf(path);
  }

  file(path: string): FileHandle {
    return new FileHandle(token, child(at(this), path));
  }

  directory(path: string): DirectoryHandle {
    return new DirectoryHandle(token, child(at(this), path));
  }

  async exists(): Promise<boolean> {
    const { host, swiplet, path } = at(this);
    const info = await host.fileStat(swiplet, path);
    return info.exists && info.directory;
  }

  async create(): Promise<void> {
    const { host, swiplet, path } = at(this);
    await host.fileMkdir(swiplet, path);
  }

  async list(): Promise<(FileHandle | DirectoryHandle)[]> {
    const location = at(this);
    const entries = await location.host.fileList(location.swiplet, location.path);
    return entries.map(entry => entry.directory ? new DirectoryHandle(token, child(location, entry.name)) : new FileHandle(token, child(location, entry.name)));
  }

  async delete(): Promise<void> {
    const { host, swiplet, path } = at(this);
    await host.fileRemove(swiplet, path);
  }

  toString(): string {
    return `Directory ${this.uri}`;
  }
}

const handleOf = (value: unknown, name: string): FileHandle => {
  if (!(value instanceof FileHandle)) {
    throw new TypeError(`${name} must be a FileHandle`);
  }
  return value;
};

export class FileHandle {
  constructor(key: symbol, location: Location) {
    guard(key);
    locations.set(this, location);
    Object.freeze(this);
  }

  get uri(): string {
    const { root, path } = at(this);
    return fileURI(root, path, false);
  }

  get name(): string {
    return nameOf(at(this).path);
  }

  async stat(): Promise<{ size: number; modified: number } | null> {
    const { host, swiplet, path } = at(this);
    const info = await host.fileStat(swiplet, path);
    return info.exists && !info.directory ? { size: info.size, modified: info.modified } : null;
  }

  async bytes(): Promise<Uint8Array> {
    const { host, swiplet, path } = at(this);
    return decodeBase64(await host.fileRead(swiplet, path));
  }

  async text(): Promise<string> {
    const { host, swiplet, path } = at(this);
    return host.fileReadText(swiplet, path);
  }

  async write(data: string | Uint8Array | Blob): Promise<void> {
    const { host, swiplet, path } = at(this);
    if (typeof data === "string") {
      await host.fileWriteText(swiplet, path, data);
      return;
    }
    if (data instanceof Uint8Array) {
      await host.fileWrite(swiplet, path, encodeBase64(data));
      return;
    }
    const blob = data as { arrayBuffer?(): Promise<ArrayBuffer> } | undefined;
    if (typeof blob?.arrayBuffer === "function") {
      await host.fileWrite(swiplet, path, encodeBase64(new Uint8Array(await blob.arrayBuffer())));
      return;
    }
    throw new TypeError("the data must be a string, a Uint8Array or a Blob");
  }

  async copy(to: FileHandle): Promise<void> {
    const { host, swiplet, path } = at(this);
    await host.fileCopy(swiplet, path, at(handleOf(to, "the destination")).path);
  }

  async move(to: FileHandle): Promise<void> {
    const { host, swiplet, path } = at(this);
    await host.fileMove(swiplet, path, at(handleOf(to, "the destination")).path);
  }

  async delete(): Promise<void> {
    const { host, swiplet, path } = at(this);
    await host.fileRemove(swiplet, path);
  }

  toString(): string {
    return `File ${this.uri}`;
  }
}

export const dataDirectoryOf = (host: FileHost, swiplet: string, root: string): DirectoryHandle =>
  new DirectoryHandle(token, { host, swiplet, root, path: "" });
