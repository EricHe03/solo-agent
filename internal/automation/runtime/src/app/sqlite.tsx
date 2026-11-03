import { createContext, memo, use, useContext, useEffect, useRef, useState, type ReactNode } from "react";

import { deepEqual, type createSQLite, type SQLiteOpenOptions, type SQLiteProviderAssetSource } from "../shared/sqlite";

type SQLite = ReturnType<typeof createSQLite>["exports"];
type SQLiteDatabase = InstanceType<SQLite["SQLiteDatabase"]>;

interface SQLiteProviderProps {
  databaseName: string;
  directory?: string;
  options?: SQLiteOpenOptions;
  assetSource?: SQLiteProviderAssetSource;
  children: ReactNode;
  onInit?: (database: SQLiteDatabase) => Promise<void>;
  onError?: (error: Error) => void;
  useSuspense?: boolean;
}

type Source = Pick<SQLiteProviderProps, "databaseName" | "directory" | "options" | "assetSource" | "onInit">;

export function sqliteHooks(sqlite: SQLite) {
  const Context = createContext<SQLiteDatabase | null>(null);
  let shared: (Omit<Source, "assetSource"> & { promise: Promise<SQLiteDatabase> }) | null = null;

  const openAsync = async ({ databaseName, directory, options, assetSource, onInit }: Source): Promise<SQLiteDatabase> => {
    if (assetSource != null) {
      await sqlite.importDatabaseFromAssetAsync(databaseName, assetSource, directory);
    }
    const database = await sqlite.openDatabaseAsync(databaseName, options, directory);
    await onInit?.(database);
    return database;
  };

  const sharedAsync = (source: Source): Promise<SQLiteDatabase> => {
    const { databaseName, directory, options, onInit } = source;
    if (shared !== null && shared.databaseName === databaseName && shared.directory === directory && shared.options === options && shared.onInit === onInit) {
      return shared.promise;
    }
    const promise = shared === null ? openAsync(source) : shared.promise.then(database => database.closeAsync(), () => {}).then(() => openAsync(source));
    shared = { databaseName, directory, options, onInit, promise };
    return promise;
  };

  function SuspenseProvider({ children, ...source }: Omit<SQLiteProviderProps, "onError" | "useSuspense">) {
    return <Context.Provider value={use(sharedAsync(source))}>{children}</Context.Provider>;
  }

  function EffectProvider({ children, onError, ...source }: Omit<SQLiteProviderProps, "useSuspense">) {
    const database = useRef<SQLiteDatabase | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<Error | null>(null);
    const { databaseName, directory, options, onInit } = source;
    useEffect(() => {
      let current = true;
      openAsync(source).then(
        opened => {
          if (!current) {
            opened.closeAsync().catch(setError);
            return;
          }
          database.current = opened;
          setLoading(false);
        },
        failure => {
          if (current) {
            setError(failure);
          }
        },
      );
      return () => {
        current = false;
        database.current?.closeAsync().catch(setError);
        database.current = null;
        setLoading(true);
      };
    }, [databaseName, directory, options, onInit]);
    if (error !== null) {
      (onError ?? (failure => { throw failure; }))(error);
    }
    if (loading || database.current === null) {
      return null;
    }
    return <Context.Provider value={database.current}>{children}</Context.Provider>;
  }

  const SQLiteProvider = memo(
    function SQLiteProvider({ children, onError, useSuspense = false, ...source }: SQLiteProviderProps) {
      if (onError != null && useSuspense) {
        throw new Error("onError can't be used with useSuspense; use an error boundary instead");
      }
      return useSuspense ? <SuspenseProvider {...source}>{children}</SuspenseProvider> : <EffectProvider {...source} onError={onError}>{children}</EffectProvider>;
    },
    (previous, next) =>
      previous.databaseName === next.databaseName &&
      deepEqual(previous.options, next.options) &&
      deepEqual(previous.assetSource, next.assetSource) &&
      previous.directory === next.directory &&
      previous.onInit === next.onInit &&
      previous.onError === next.onError &&
      previous.useSuspense === next.useSuspense,
  );

  const useSQLiteContext = (): SQLiteDatabase => {
    const database = useContext(Context);
    if (database === null) {
      throw new Error("useSQLiteContext must be used within a <SQLiteProvider>");
    }
    return database;
  };

  return { SQLiteProvider, useSQLiteContext };
}
