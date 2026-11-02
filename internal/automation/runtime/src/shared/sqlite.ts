import { decodeBase64, encodeBase64 } from "./base64";

export interface DatabaseChangeEvent {
  databaseName: string;
  databaseFilePath: string;
  tableName: string;
  rowId: number;
}

export interface SQLiteBridge {
  request(request: Record<string, unknown>): unknown;
  readonly defaultDirectory: string;
  subscribe(listener: (event: DatabaseChangeEvent) => void): () => void;
}

export type SQLiteBindValue = string | number | boolean | bigint | null | Uint8Array;
export type SQLiteBindParams = Record<string, SQLiteBindValue> | SQLiteBindValue[];
export type SQLiteVariadicBindParams = SQLiteBindValue[];

export interface SQLiteRunResult {
  lastInsertRowId: number;
  changes: number;
}

export interface SQLiteOpenOptions {
  enableChangeListener?: boolean;
  useNewConnection?: boolean;
  [key: string]: unknown;
}

interface Opened {
  handle: number;
  path: string;
}

interface Prepared {
  statement: number;
  columns: string[];
}

interface Ran {
  changes: number;
  lastInsertRowId: number;
  columns: string[];
  rows: unknown[][];
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

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value) && !(value instanceof Uint8Array);

const encodeValue = (value: unknown): unknown => {
  switch (typeof value) {
    case "undefined":
      return null;
    case "bigint":
      return { $i: value.toString() };
    case "number":
    case "string":
    case "boolean":
      return value;
    case "object":
      if (value === null) {
        return null;
      }
      if (value instanceof Uint8Array) {
        return { $b: encodeBase64(value) };
      }
      if (value instanceof Date) {
        return value.toISOString();
      }
      break;
  }
  throw new TypeError(`a parameter must be null, a number, a string, a boolean, a bigint or a Uint8Array, not ${typeof value}`);
};

const encodeParams = (params: unknown[]): unknown => {
  if (params.length === 1 && params[0] == null) {
    return [];
  }
  if (params.length === 1 && Array.isArray(params[0])) {
    return params[0].map(encodeValue);
  }
  if (params.length === 1 && isPlainObject(params[0])) {
    return Object.fromEntries(Object.entries(params[0]).map(([key, value]) => [key, encodeValue(value)]));
  }
  return params.map(encodeValue);
};

const decodeValue = (value: unknown): unknown => (isPlainObject(value) && typeof value.$b === "string" ? decodeBase64(value.$b) : value);

const toObjects = <T>(columns: string[], rows: unknown[][]): T[] =>
  rows.map(row => {
    const object: Record<string, unknown> = {};
    for (let index = 0; index < columns.length; index++) {
      object[columns[index]] = decodeValue(row[index]);
    }
    return object as T;
  });

const toArrays = <T>(rows: unknown[][]): T[] => rows.map(row => row.map(decodeValue) as T);

const nameOf = (path: string) => path.slice(path.lastIndexOf("/") + 1);

export function createSQLite(bridge: SQLiteBridge) {
  const request = <T>(call: Record<string, unknown>): T => bridge.request(call) as T;
  const databases = new Set<SQLiteDatabase>();

  const finalizedByHost = (error: unknown) => error instanceof Error && error.message.includes("the statement is finalized");

  class SQLiteStatement {
    #handle: number;
    #source: string;
    #id: number | null;
    #columns: string[];

    constructor(handle: number, source: string, prepared: Prepared) {
      this.#handle = handle;
      this.#source = source;
      this.#id = prepared.statement;
      this.#columns = prepared.columns;
    }

    #run(params: unknown[]): Ran {
      if (this.#id === null) {
        throw new Error("the statement is finalized");
      }
      const call = { op: "run", handle: this.#handle, statement: this.#id, params: encodeParams(params) };
      try {
        return request<Ran>(call);
      } catch (error) {
        if (!finalizedByHost(error)) {
          throw error;
        }
        const prepared = request<Prepared>({ op: "prepare", handle: this.#handle, sql: this.#source });
        this.#id = prepared.statement;
        this.#columns = prepared.columns;
        return request<Ran>({ ...call, statement: this.#id });
      }
    }

    #result<T>(params: unknown[], raw: boolean): SQLiteExecuteSyncResult<T> {
      const run = () => {
        const ran = this.#run(params);
        return { ran, rows: raw ? toArrays<T>(ran.rows) : toObjects<T>(ran.columns, ran.rows) };
      };
      const { ran: first, rows: firstRows } = run();
      let rows = firstRows;
      let cursor = 0;
      const result: SQLiteExecuteSyncResult<T> = {
        lastInsertRowId: first.lastInsertRowId,
        changes: first.changes,
        getFirstSync: () => {
          const value = rows[cursor] ?? null;
          cursor = rows.length;
          return value;
        },
        getAllSync: () => {
          const rest = rows.slice(cursor);
          cursor = rows.length;
          return rest;
        },
        resetSync: () => {
          rows = run().rows;
          cursor = 0;
        },
        next: () => (cursor < rows.length ? { value: rows[cursor++], done: false } : { value: undefined, done: true }),
        [Symbol.iterator]() {
          return this;
        },
      };
      return result;
    }

    #asyncResult<T>(sync: SQLiteExecuteSyncResult<T>): SQLiteExecuteAsyncResult<T> {
      return {
        lastInsertRowId: sync.lastInsertRowId,
        changes: sync.changes,
        getFirstAsync: async () => sync.getFirstSync(),
        getAllAsync: async () => sync.getAllSync(),
        resetAsync: async () => sync.resetSync(),
        next: async () => sync.next(),
        [Symbol.asyncIterator]() {
          return this;
        },
      };
    }

    executeSync<T>(...params: unknown[]): SQLiteExecuteSyncResult<T> {
      return this.#result<T>(params, false);
    }

    executeForRawResultSync<T>(...params: unknown[]): SQLiteExecuteSyncResult<T> {
      return this.#result<T>(params, true);
    }

    async executeAsync<T>(...params: unknown[]): Promise<SQLiteExecuteAsyncResult<T>> {
      return this.#asyncResult(this.#result<T>(params, false));
    }

    async executeForRawResultAsync<T>(...params: unknown[]): Promise<SQLiteExecuteAsyncResult<T>> {
      return this.#asyncResult(this.#result<T>(params, true));
    }

    getColumnNamesSync(): string[] {
      return [...this.#columns];
    }

    async getColumnNamesAsync(): Promise<string[]> {
      return this.getColumnNamesSync();
    }

    finalizeSync(): void {
      if (this.#id !== null) {
        const id = this.#id;
        this.#id = null;
        request({ op: "finalize", handle: this.#handle, statement: id });
      }
    }

    async finalizeAsync(): Promise<void> {
      this.finalizeSync();
    }
  }

  class SQLiteDatabase {
    readonly databasePath: string;
    readonly options: SQLiteOpenOptions;
    #handle: number | null;

    constructor(options: SQLiteOpenOptions, opened: Opened) {
      this.databasePath = opened.path;
      this.options = options;
      this.#handle = opened.handle;
      databases.add(this);
    }

    get databaseName(): string {
      return nameOf(this.databasePath);
    }

    get #open(): number {
      if (this.#handle === null) {
        throw new Error("the database is closed");
      }
      return this.#handle;
    }

    isInTransactionSync(): boolean {
      return !request<boolean>({ op: "autocommit", handle: this.#open });
    }

    async isInTransactionAsync(): Promise<boolean> {
      return this.isInTransactionSync();
    }

    closeSync(): void {
      if (this.#handle !== null) {
        const handle = this.#handle;
        this.#handle = null;
        databases.delete(this);
        request({ op: "close", handle });
      }
    }

    async closeAsync(): Promise<void> {
      this.closeSync();
    }

    execSync(source: string): void {
      request({ op: "exec", handle: this.#open, sql: String(source) });
    }

    async execAsync(source: string): Promise<void> {
      this.execSync(source);
    }

    prepareSync(source: string): SQLiteStatement {
      const handle = this.#open;
      return new SQLiteStatement(handle, String(source), request<Prepared>({ op: "prepare", handle, sql: String(source) }));
    }

    async prepareAsync(source: string): Promise<SQLiteStatement> {
      return this.prepareSync(source);
    }

    #with<T>(source: string, work: (statement: SQLiteStatement) => T): T {
      const statement = this.prepareSync(source);
      try {
        return work(statement);
      } finally {
        statement.finalizeSync();
      }
    }

    runSync(source: string, ...params: unknown[]): SQLiteRunResult {
      return this.#with(source, statement => {
        const { lastInsertRowId, changes } = statement.executeSync(...params);
        return { lastInsertRowId, changes };
      });
    }

    async runAsync(source: string, ...params: unknown[]): Promise<SQLiteRunResult> {
      return this.runSync(source, ...params);
    }

    getFirstSync<T>(source: string, ...params: unknown[]): T | null {
      return this.#with(source, statement => statement.executeSync<T>(...params).getFirstSync());
    }

    async getFirstAsync<T>(source: string, ...params: unknown[]): Promise<T | null> {
      return this.getFirstSync<T>(source, ...params);
    }

    getAllSync<T>(source: string, ...params: unknown[]): T[] {
      return this.#with(source, statement => statement.executeSync<T>(...params).getAllSync());
    }

    async getAllAsync<T>(source: string, ...params: unknown[]): Promise<T[]> {
      return this.getAllSync<T>(source, ...params);
    }

    *getEachSync<T>(source: string, ...params: unknown[]): IterableIterator<T> {
      yield* this.getAllSync<T>(source, ...params);
    }

    async *getEachAsync<T>(source: string, ...params: unknown[]): AsyncIterableIterator<T> {
      yield* this.getAllSync<T>(source, ...params);
    }

    withTransactionSync(task: () => void): void {
      this.execSync("BEGIN");
      try {
        task();
        this.execSync("COMMIT");
      } catch (error) {
        if (this.isInTransactionSync()) {
          this.execSync("ROLLBACK");
        }
        throw error;
      }
    }

    async withTransactionAsync(task: () => Promise<void>): Promise<void> {
      this.execSync("BEGIN");
      try {
        await task();
        this.execSync("COMMIT");
      } catch (error) {
        if (this.isInTransactionSync()) {
          this.execSync("ROLLBACK");
        }
        throw error;
      }
    }

    async withExclusiveTransactionAsync(task: (transaction: SQLiteDatabase) => Promise<void>): Promise<void> {
      await this.withTransactionAsync(() => task(this));
    }

    serializeSync(): never {
      throw new Error("serializing databases is not supported by Swipt");
    }

    serializeAsync(): Promise<never> {
      return Promise.reject(new Error("serializing databases is not supported by Swipt"));
    }

    loadExtensionSync(): never {
      throw new Error("SQLite extensions are not supported by Swipt");
    }

    loadExtensionAsync(): Promise<never> {
      return Promise.reject(new Error("SQLite extensions are not supported by Swipt"));
    }

    createSessionSync(): never {
      throw new Error("SQLite sessions are not supported by Swipt");
    }

    createSessionAsync(): Promise<never> {
      return Promise.reject(new Error("SQLite sessions are not supported by Swipt"));
    }

    syncLibSQL(): Promise<never> {
      return Promise.reject(new Error("libSQL is not supported by Swipt"));
    }
  }

  const checkName = (name: unknown): string => {
    if (typeof name !== "string" || name === "") {
      throw new TypeError("the database name must be a non-empty string");
    }
    return name;
  };

  const checkDirectory = (directory: string | undefined) => {
    if (directory !== undefined && directory !== bridge.defaultDirectory) {
      throw new Error("Swipt keeps the databases of a swiplet in its data directory; pass a relative name instead of a directory");
    }
  };

  const openDatabaseSync = (name: string, options: SQLiteOpenOptions = {}, directory?: string): SQLiteDatabase => {
    checkDirectory(directory);
    return new SQLiteDatabase(options, request<Opened>({ op: "open", path: checkName(name), changes: options.enableChangeListener === true }));
  };

  const openDatabaseAsync = async (name: string, options?: SQLiteOpenOptions, directory?: string): Promise<SQLiteDatabase> =>
    openDatabaseSync(name, options, directory);

  const deleteDatabaseSync = (name: string, directory?: string): void => {
    checkDirectory(directory);
    request({ op: "delete", path: checkName(name) });
  };

  const deleteDatabaseAsync = async (name: string, directory?: string): Promise<void> => deleteDatabaseSync(name, directory);

  const listeners = new Set<(event: DatabaseChangeEvent) => void>();
  let stop: (() => void) | undefined;

  const addDatabaseChangeListener = (listener: (event: DatabaseChangeEvent) => void) => {
    if (typeof listener !== "function") {
      throw new TypeError("the listener is not a function");
    }
    listeners.add(listener);
    stop ??= bridge.subscribe(event => {
      for (const current of [...listeners]) {
        current(event);
      }
    });
    let removed = false;
    return {
      remove() {
        if (removed) {
          return;
        }
        removed = true;
        listeners.delete(listener);
        if (listeners.size === 0 && stop !== undefined) {
          const current = stop;
          stop = undefined;
          current();
        }
      },
    };
  };

  const unsupported = (name: string) => () => {
    throw new Error(`${name} is not supported by Swipt`);
  };

  const exports = Object.freeze({
    __esModule: true,
    SQLiteDatabase,
    SQLiteStatement,
    openDatabaseSync,
    openDatabaseAsync,
    deleteDatabaseSync,
    deleteDatabaseAsync,
    addDatabaseChangeListener,
    defaultDatabaseDirectory: bridge.defaultDirectory,
    deserializeDatabaseSync: unsupported("deserializeDatabaseSync"),
    deserializeDatabaseAsync: unsupported("deserializeDatabaseAsync"),
    backupDatabaseSync: unsupported("backupDatabaseSync"),
    backupDatabaseAsync: unsupported("backupDatabaseAsync"),
  });

  const close = () => {
    for (const database of [...databases]) {
      database.closeSync();
    }
    listeners.clear();
    stop?.();
    stop = undefined;
  };

  return { exports, close };
}
