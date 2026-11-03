export declare const dataDirectory: DirectoryHandle;
/**
 * Holds the files Swipt keeps for the Swiplet by default: screen recordings and their exports, and application icons.
 * The system may delete its contents when storage runs low; clearing the Swiplet's data or deleting the Swiplet removes it.
 */
export declare const cacheDirectory: DirectoryHandle;
export declare const assets: DirectoryHandle;

export interface FileStat {
  readonly size: number;
  readonly modified: number;
}

export interface DirectoryHandle {
  readonly uri: string;
  readonly name: string;
  file(path: string): FileHandle;
  directory(path: string): DirectoryHandle;
  exists(): Promise<boolean>;
  create(): Promise<void>;
  list(): Promise<(FileHandle | DirectoryHandle)[]>;
  delete(): Promise<void>;
}

export interface FileHandle {
  readonly uri: string;
  readonly name: string;
  stat(): Promise<FileStat | null>;
  text(): Promise<string>;
  bytes(): Promise<Uint8Array>;
  stream(): ReadableStream<Uint8Array>;
  write(data: string | ArrayBuffer | ArrayBufferView | Blob | ReadableStream<ArrayBuffer | ArrayBufferView>): Promise<void>;
  copy(to: FileHandle): Promise<void>;
  move(to: FileHandle): Promise<void>;
  delete(): Promise<void>;
}
