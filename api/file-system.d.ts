export declare const dataDirectory: DirectoryHandle;
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
  write(data: string | Uint8Array | Blob | ReadableStream<Uint8Array>): Promise<void>;
  copy(to: FileHandle): Promise<void>;
  move(to: FileHandle): Promise<void>;
  delete(): Promise<void>;
}
