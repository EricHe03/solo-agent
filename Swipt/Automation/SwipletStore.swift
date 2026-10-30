import CoreTransferable
import Foundation
import LibSwipt
import Perception
internal import SwiptHost
import UniformTypeIdentifiers

@Perceptible
final class SwipletStore {
    static let shared = SwipletStore()
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Swiplets", isDirectory: true)

    private(set) var ids: [String] = []
    private(set) var directories: [String: URL] = [:]
    private(set) var icons: [String: SwipletIcon] = [:]
    private(set) var titles: [String: String] = [:]
    private(set) var interfaces: [String: SwipletEntry] = [:]
    private(set) var actions: [String: [SwipletAction]] = [:]
    private(set) var withServices: Set<String> = []
    private(set) var services: [String: SwipletService] = [:]
    private(set) var updatable: Set<String> = []
    private(set) var updates: [String: SwipletUpdate] = [:]
    private(set) var updating: Set<String> = []
    @PerceptionIgnored private var manifests: [String: LibSwiptSwipletManifest] = [:]
    private var checked: [String: Date] = [:]

    func reload() {
        let swiplets = Platform.shared.swiplets()
        manifests = Dictionary(uniqueKeysWithValues: swiplets.compactMap { swiplet in swiplet.manifest.map { (swiplet.id_, $0) } })
        directories = Dictionary(uniqueKeysWithValues: swiplets.map { ($0.id_, URL(fileURLWithPath: $0.directory, isDirectory: true)) })
        titles = manifests.mapValues { manifest in
            let title = Self.preferredName(manifest)
            return title.isEmpty ? manifest.id_ : title
        }
        ids = swiplets.map(\.id_).sorted { (titles[$0] ?? $0).localizedStandardCompare(titles[$1] ?? $1) == .orderedAscending }
        icons = directories.mapValues { SwipletIcon.load(from: $0) }
        interfaces = directories.compactMapValues { directory in
            let entry = directory
                .appendingPathComponent(LibSwiptSwipletSourceFolder, isDirectory: true)
                .appendingPathComponent(LibSwiptSwipletInterfaceFile)
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
            return SwipletEntry(url: entry, modified: modified)
        }
        actions = manifests.mapValues { manifest in
            (0..<manifest.actionCount()).map { index in
                SwipletAction(
                    name: manifest.actionName(index), title: manifest.actionTitle(index), description: manifest.actionDescription(index),
                    shortcuts: manifest.actionExposed(index, caller: LibSwiptCallerShortcuts))
            }
        }
        withServices = Set(manifests.filter { $0.value.service }.keys)
        services = Dictionary(uniqueKeysWithValues: withServices.map { ($0, Platform.shared.serviceState(of: $0)) })
        updatable = Set(manifests.filter { !$0.value.version.isEmpty && !$0.value.updateURL.isEmpty }.keys)
    }

    var hasEnabledServices: Bool {
        services.values.contains(where: \.enabled)
    }

    func service(of id: String) -> SwipletService {
        services[id] ?? SwipletService()
    }

    func dataDirectory(of id: String) -> URL? {
        directories[id]?.appendingPathComponent(LibSwiptSwipletDataFolder, isDirectory: true)
    }

    func serviceChanged(_ id: String, to service: SwipletService) {
        services[id] = service
        SwiptHostModule.send("service", [
            "name": id, "enabled": service.enabled, "status": service.status.rawValue, "error": service.error,
            "since": service.since.map { $0.timeIntervalSince1970 * 1000 } ?? 0,
        ])
    }

    func setServiceEnabled(_ id: String, _ enabled: Bool) async throws {
        try await Platform.shared.setServiceEnabled(id, enabled)
    }

    @available(iOS 27, *)
    func importSwiplet(from picked: URL) async throws {
        defer { reload() }
        _ = try await Platform.shared.installSwiplet(picked: picked)
    }

    @available(iOS 27, *)
    func importSwiplet(downloadingFrom link: String) async throws {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let download = try await Self.download(link)
        defer {
            Self.discard(download.file)
            reload()
        }
        let id = try await Platform.shared.installSwiplet(download.file)
        if download.updateURL == link {
            try Platform.shared.setETag(download.etag, of: id)
        }
    }

    @available(iOS 27, *)
    func checkForUpdates(of ids: [String]) async {
        for id in ids where updatable.contains(id) {
            if let last = checked[id], Date.now.timeIntervalSince(last) < Self.updateInterval {
                continue
            }
            try? await checkForUpdate(of: id)
        }
    }

    @available(iOS 27, *)
    func checkForUpdate(of id: String) async throws {
        checked[id] = .now
        guard let local = manifests[id], !local.version.isEmpty, !local.updateURL.isEmpty else { return }
        let download = try await Self.download(local.updateURL, etag: Platform.shared.etag(of: id), version: local.version)
        if download.version == local.version {
            do {
                try Platform.shared.setETag(download.etag, of: id)
            } catch {
                Self.discard(download.file)
                throw error
            }
        }
        guard !download.version.isEmpty, download.version != local.version else {
            Self.discard(download.file)
            return
        }
        guard download.id == id else {
            Self.discard(download.file)
            throw MessageError(String(localized: "The update is a different swiplet."))
        }
        let update = SwipletUpdate(id: id, file: download.file, version: download.version, etag: download.etag)
        if download.url.hasPrefix(Self.trustedPrefix), (try? await applyUpdate(update)) != nil {
            return
        }
        if let previous = updates[id] {
            Self.discard(previous.file)
        }
        updates[id] = update
    }

    @available(iOS 27, *)
    func applyUpdate(_ update: SwipletUpdate) async throws {
        updating.insert(update.id)
        defer { updating.remove(update.id) }
        _ = try await Platform.shared.installSwiplet(update.file)
        try Platform.shared.setETag(update.etag, of: update.id)
        Self.discard(update.file)
        updates[update.id] = nil
        reload()
    }

    nonisolated private static let updateInterval: TimeInterval = 60 * 60

    nonisolated private static func download(_ link: String, etag: String = "", version: String = "") async throws -> SwipletDownload {
        let file = try temporaryFile()
        let downloader = UncheckedSendable(value: LibSwiptNewSwipletDownloader()!)
        do {
            return try await withTaskCancellationHandler {
                try await blocking {
                    let download = downloader.value.download(link, destination: file.path, etag: etag, version: version)!
                    switch download.errorCode {
                    case LibSwiptSwipletErrorNone:
                        let declared = FileManager.default.fileExists(atPath: file.path) ? (try? manifest(of: file))?.updateURL ?? "" : ""
                        return SwipletDownload(
                            file: file, url: download.url, etag: download.entityTag, id: download.id_, version: download.version, updateURL: declared)
                    case LibSwiptSwipletErrorTimeout:
                        throw MessageError(String(localized: "The connection timed out."))
                    default:
                        throw MessageError(download.errorMessage)
                    }
                }
            } onCancel: {
                downloader.value.cancel()
            }
        } catch {
            discard(file)
            throw error
        }
    }

    nonisolated private static func manifest(of file: URL) throws -> LibSwiptSwipletManifest? {
        var error: NSError?
        let manifest = LibSwiptReadSwipletManifest(file.path, &error)
        if let error { throw error }
        return manifest
    }

    nonisolated private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    nonisolated private static let trustedPrefix = "https://codeload.github.com/swipt-automation/swipt/"

    nonisolated private static func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("swiplet")
    }

    @available(iOS 27, *)
    func export(_ id: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id).appendingPathExtension(for: .zip)
        try await Platform.shared.exportSwiplet(id, to: file)
        return file
    }

    nonisolated private static func preferredName(_ names: LibSwiptSwipletManifest) -> String {
        var localized = ["en": ""]
        var languages = ["en"]
        for index in 0..<names.len() {
            let language = names.language(index)
            localized[language.isEmpty ? "en" : language] = names.name(index)
            if !language.isEmpty, language != "en" {
                languages.append(language)
            }
        }
        let preferred = Bundle.preferredLocalizations(from: languages, forPreferences: Locale.preferredLanguages).first ?? "en"
        return localized[preferred] ?? ""
    }

    private func forgetUpdate(of id: String) {
        if let update = updates.removeValue(forKey: id) {
            Self.discard(update.file)
        }
        checked[id] = nil
    }

    func remove(_ id: String) async throws {
        defer { reload() }
        forgetUpdate(of: id)
        try await Platform.shared.removeSwiplet(id)
    }
}

@available(iOS 27, *)
nonisolated struct SwipletFile: Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { swiplet in
            SentTransferredFile(try await SwipletStore.shared.export(swiplet.id))
        }
    }
}

nonisolated struct SwipletEntry: Hashable, Sendable {
    let url: URL
    let modified: Date
}

nonisolated struct SwipletAction: Hashable, Sendable {
    let name: String
    let title: String
    let description: String
    let shortcuts: Bool
}

nonisolated struct SwipletUpdate: Sendable {
    let id: String
    let file: URL
    let version: String
    let etag: String
}

nonisolated private struct SwipletDownload: Sendable {
    let file: URL
    let url: String
    let etag: String
    let id: String
    let version: String
    let updateURL: String
}
