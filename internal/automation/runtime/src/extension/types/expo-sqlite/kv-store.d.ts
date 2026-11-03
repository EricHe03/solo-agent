export type SQLiteStorageSetItemUpdateFunction = (
  previous: string | null,
) => string;

export declare class SQLiteStorage {
  constructor(databaseName: string);
  getItemSync(key: string): string | null;
  getItemAsync(key: string): Promise<string | null>;
  getItem(key: string): Promise<string | null>;
  setItemSync(
    key: string,
    value: string | SQLiteStorageSetItemUpdateFunction,
  ): void;
  setItemAsync(
    key: string,
    value: string | SQLiteStorageSetItemUpdateFunction,
  ): Promise<void>;
  setItem(
    key: string,
    value: string | SQLiteStorageSetItemUpdateFunction,
  ): Promise<void>;
  removeItemSync(key: string): boolean;
  removeItemAsync(key: string): Promise<boolean>;
  removeItem(key: string): Promise<void>;
  getAllKeysSync(): string[];
  getAllKeysAsync(): Promise<string[]>;
  getAllKeys(): Promise<string[]>;
  clearSync(): boolean;
  clearAsync(): Promise<boolean>;
  clear(): Promise<void>;
  getLengthSync(): number;
  getLengthAsync(): Promise<number>;
  getKeyByIndexSync(index: number): string | null;
  getKeyByIndexAsync(index: number): Promise<string | null>;
  mergeItem(key: string, value: string): Promise<void>;
  multiGet(keys: string[]): Promise<[string, string | null][]>;
  multiSet(pairs: [string, string][]): Promise<void>;
  multiRemove(keys: string[]): Promise<void>;
  multiMerge(pairs: [string, string][]): Promise<void>;
  closeSync(): void;
  closeAsync(): Promise<void>;
}

export declare const AsyncStorage: SQLiteStorage;
export declare const Storage: SQLiteStorage;
export default Storage;
