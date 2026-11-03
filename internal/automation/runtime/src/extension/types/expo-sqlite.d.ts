export type SQLiteBindValue =
  string | number | boolean | bigint | null | Uint8Array;
export type SQLiteBindParams =
  Record<string, SQLiteBindValue> | SQLiteBindValue[];
export type SQLiteVariadicBindParams = SQLiteBindValue[];

export interface SQLiteOpenOptions {
  enableChangeListener?: boolean;
  useNewConnection?: boolean;
  [key: string]: unknown;
}

export interface SQLiteRunResult {
  lastInsertRowId: number;
  changes: number;
}

export interface SQLiteExecuteSyncResult<T> extends IterableIterator<T> {
  readonly lastInsertRowId: number;
  readonly changes: number;
  getFirstSync(): T | null;
  getAllSync(): T[];
  resetSync(): void;
}

export interface SQLiteExecuteAsyncResult<T> extends AsyncIterableIterator<T> {
  readonly lastInsertRowId: number;
  readonly changes: number;
  getFirstAsync(): Promise<T | null>;
  getAllAsync(): Promise<T[]>;
  resetAsync(): Promise<void>;
}

export interface SQLiteStatement {
  executeSync<T>(params: SQLiteBindParams): SQLiteExecuteSyncResult<T>;
  executeSync<T>(
    ...params: SQLiteVariadicBindParams
  ): SQLiteExecuteSyncResult<T>;
  executeForRawResultSync<T extends unknown[]>(
    params: SQLiteBindParams,
  ): SQLiteExecuteSyncResult<T>;
  executeForRawResultSync<T extends unknown[]>(
    ...params: SQLiteVariadicBindParams
  ): SQLiteExecuteSyncResult<T>;
  executeAsync<T>(
    params: SQLiteBindParams,
  ): Promise<SQLiteExecuteAsyncResult<T>>;
  executeAsync<T>(
    ...params: SQLiteVariadicBindParams
  ): Promise<SQLiteExecuteAsyncResult<T>>;
  executeForRawResultAsync<T extends unknown[]>(
    params: SQLiteBindParams,
  ): Promise<SQLiteExecuteAsyncResult<T>>;
  executeForRawResultAsync<T extends unknown[]>(
    ...params: SQLiteVariadicBindParams
  ): Promise<SQLiteExecuteAsyncResult<T>>;
  getColumnNamesSync(): string[];
  getColumnNamesAsync(): Promise<string[]>;
  finalizeSync(): void;
  finalizeAsync(): Promise<void>;
}

export declare const SQLiteStatement: abstract new (
  ...args: never
) => SQLiteStatement;

export interface SQLiteTaggedQuery<T = unknown> extends PromiseLike<
  T[] | SQLiteRunResult
> {
  values(): Promise<unknown[][]>;
  first(): Promise<T | null>;
  each(): AsyncIterableIterator<T>;
  allSync(): T[] | SQLiteRunResult;
  valuesSync(): unknown[][];
  firstSync(): T | null;
  eachSync(): IterableIterator<T>;
}

export declare const SQLiteTaggedQuery: abstract new (
  ...args: never
) => SQLiteTaggedQuery;

export interface SQLiteDatabase {
  readonly databasePath: string;
  readonly options: SQLiteOpenOptions;
  readonly databaseName: string;
  sql<T = unknown>(
    strings: TemplateStringsArray,
    ...values: SQLiteBindValue[]
  ): SQLiteTaggedQuery<T>;
  isInTransactionSync(): boolean;
  isInTransactionAsync(): Promise<boolean>;
  interruptSync(): void;
  closeSync(): void;
  closeAsync(): Promise<void>;
  execSync(source: string): void;
  execAsync(source: string): Promise<void>;
  prepareSync(source: string): SQLiteStatement;
  prepareAsync(source: string): Promise<SQLiteStatement>;
  runSync(source: string, params: SQLiteBindParams): SQLiteRunResult;
  runSync(source: string, ...params: SQLiteVariadicBindParams): SQLiteRunResult;
  runAsync(source: string, params: SQLiteBindParams): Promise<SQLiteRunResult>;
  runAsync(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): Promise<SQLiteRunResult>;
  getFirstSync<T>(source: string, params: SQLiteBindParams): T | null;
  getFirstSync<T>(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): T | null;
  getFirstAsync<T>(source: string, params: SQLiteBindParams): Promise<T | null>;
  getFirstAsync<T>(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): Promise<T | null>;
  getAllSync<T>(source: string, params: SQLiteBindParams): T[];
  getAllSync<T>(source: string, ...params: SQLiteVariadicBindParams): T[];
  getAllAsync<T>(source: string, params: SQLiteBindParams): Promise<T[]>;
  getAllAsync<T>(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): Promise<T[]>;
  getEachSync<T>(source: string, params: SQLiteBindParams): IterableIterator<T>;
  getEachSync<T>(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): IterableIterator<T>;
  getEachAsync<T>(
    source: string,
    params: SQLiteBindParams,
  ): AsyncIterableIterator<T>;
  getEachAsync<T>(
    source: string,
    ...params: SQLiteVariadicBindParams
  ): AsyncIterableIterator<T>;
  withTransactionSync(task: () => void): void;
  withTransactionAsync(task: () => Promise<void>): Promise<void>;
  withExclusiveTransactionAsync(
    task: (transaction: SQLiteDatabase) => Promise<void>,
  ): Promise<void>;
  serializeSync(databaseName?: string): Uint8Array;
  serializeAsync(databaseName?: string): Promise<Uint8Array>;
  loadExtensionSync(libPath: string, entryPoint?: string): never;
  loadExtensionAsync(libPath: string, entryPoint?: string): Promise<never>;
  createSessionSync(databaseName?: string): never;
  createSessionAsync(databaseName?: string): Promise<never>;
  syncLibSQL(): Promise<never>;
}

export declare const SQLiteDatabase: abstract new (
  ...args: never
) => SQLiteDatabase;

export interface SQLiteSession {}

export declare const SQLiteSession: abstract new (
  ...args: never
) => SQLiteSession;

export interface DatabaseChangeEvent {
  databaseName: string;
  databaseFilePath: string;
  tableName: string;
  rowId: number;
}

export interface SQLiteBackupOptions {
  sourceDatabase: SQLiteDatabase;
  sourceDatabaseName?: string;
  destDatabase: SQLiteDatabase;
  destDatabaseName?: string;
}

export interface SQLiteProviderAssetSource {
  assetId: number;
  forceOverwrite?: boolean;
}

export declare const defaultDatabaseDirectory: string;
export declare const bundledExtensions: Readonly<
  Record<string, { libPath: string; entryPoint: string } | undefined>
>;
export declare function openDatabaseSync(
  databaseName: string,
  options?: SQLiteOpenOptions,
  directory?: string,
): SQLiteDatabase;
export declare function openDatabaseAsync(
  databaseName: string,
  options?: SQLiteOpenOptions,
  directory?: string,
): Promise<SQLiteDatabase>;
export declare function deserializeDatabaseSync(
  serializedData: Uint8Array,
  options?: SQLiteOpenOptions,
): SQLiteDatabase;
export declare function deserializeDatabaseAsync(
  serializedData: Uint8Array,
  options?: SQLiteOpenOptions,
): Promise<SQLiteDatabase>;
export declare function deleteDatabaseSync(
  databaseName: string,
  directory?: string,
): void;
export declare function deleteDatabaseAsync(
  databaseName: string,
  directory?: string,
): Promise<void>;
export declare function importDatabaseFromAssetAsync(
  databaseName: string,
  assetSource: SQLiteProviderAssetSource,
  directory?: string,
): Promise<void>;
export declare function backupDatabaseSync(options: SQLiteBackupOptions): void;
export declare function backupDatabaseAsync(
  options: SQLiteBackupOptions,
): Promise<void>;
export declare function addDatabaseChangeListener(
  listener: (event: DatabaseChangeEvent) => void,
): { remove(): void };
export declare function deepEqual(a: unknown, b: unknown): boolean;
export declare function configureWeb(options?: unknown): void;
export declare function SQLiteProvider(props: unknown): never;
export declare function useSQLiteContext(): never;
