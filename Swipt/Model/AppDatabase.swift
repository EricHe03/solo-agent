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
        migrator.registerMigration("0.1.0", migrate: createTables)
        return migrator
    }()

    private nonisolated static func createTables(_ db: Database) throws {
        try db.create(table: "preferences", options: .ifNotExists) { t in
            t.primaryKey("name", .text)
            t.column("data", .blob).notNull()
        }
        try db.create(table: "swiplets", options: .ifNotExists) { t in
            t.primaryKey("id", .text)
            t.column("position", .integer).notNull()
            t.column("etag", .text).notNull()
        }
        try db.create(table: "repositories", options: .ifNotExists) { t in
            t.primaryKey("url", .text)
            t.column("position", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("localizedNames", .text)
            t.column("iconColor", .text)
            t.column("iconSymbol", .text)
            t.column("image", .blob)
            t.column("etag", .text).notNull()
        }
        try db.create(table: "repositorySwiplets", options: .ifNotExists) { t in
            t.column("repository", .text).notNull().references("repositories", onDelete: .cascade)
            t.column("position", .integer).notNull()
            t.column("id", .text).notNull()
            t.column("name", .text).notNull()
            t.column("localizedNames", .text).notNull()
            t.column("description", .text).notNull()
            t.column("version", .text).notNull()
            t.column("versionCode", .integer).notNull()
            t.column("iconColor", .text)
            t.column("iconSymbol", .text)
            t.column("url", .text).notNull()
            t.column("sha256", .text).notNull()
            t.primaryKey(["repository", "id"])
        }
    }
}
