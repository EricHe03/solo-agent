import Foundation
import GRDB
import os

enum AppDatabase {
    private static let url: URL = {
        #if os(iOS)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let directory = AppDirectory.group
        #endif
        return directory.appendingPathComponent("Swipt.sqlite")
    }()

    static let shared = open()

    private static func open() -> DatabaseQueue {
        do {
            do {
                return try load()
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                AppDirectory.logger.error("reset \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                for path in [url.path, url.path + "-journal", url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                return try load()
            }
        } catch {
            fatalError("cannot open \(url.lastPathComponent): \(error)")
        }
    }

    private static func load() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: url.path)
        let expected = try DatabaseQueue()
        try migrator.migrate(expected)
        do {
            try migrator.migrate(database)
        } catch {
            AppDirectory.logger.error("migrate \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
        if try database.read(schema) != expected.read(schema) {
            AppDirectory.logger.error("erase \(url.lastPathComponent, privacy: .public) saved with a different schema")
            try database.erase()
            try migrator.migrate(database)
        }
        return database
    }

    private nonisolated static func schema(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name != 'grdb_migrations' ORDER BY name")
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("1.0.0", migrate: createTables)
        return migrator
    }()

    private nonisolated static func createTables(_ db: Database) throws {
        try db.create(table: "preferences", options: .ifNotExists) { t in
            t.primaryKey("name", .text)
            t.column("data", .blob).notNull()
        }
    }
}
