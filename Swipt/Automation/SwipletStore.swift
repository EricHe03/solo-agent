import CoreTransferable
import CryptoKit
import Foundation
import LibSwipt
import Perception
internal import SwiptHost
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let swiplet = UTType(exportedAs: "io.nekohasekai.swipt.swiplet", conformingTo: .zip)
}

@Perceptible
final class SwipletStore {
    static let shared = SwipletStore()
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Swiplets", isDirectory: true)
    nonisolated static let officialSource = URL(string: "https://github.com/swipt-automation/swiplets-official/releases/download/nightly/swiplets.json")!

    private(set) var ids: [String] = []
    private(set) var directories: [String: URL] = [:]
    private(set) var icons: [String: SwipletIcon] = [:]
    private(set) var titles: [String: String] = [:]
    private(set) var versions: [String: String] = [:]
    private(set) var interfaces: [String: SwipletEntry] = [:]
    private(set) var actions: [String: [SwipletAction]] = [:]
    private(set) var withServices: Set<String> = []
    private(set) var services: [String: SwipletService] = [:]
    private(set) var updatable: Set<String> = []
    private(set) var official: Set<String> = []
    private(set) var updates: [String: SwipletUpdate] = [:]
    private(set) var updating: Set<String> = []
    private(set) var officialSwiplets: [OfficialSwiplet] = SwipletStore.cachedOfficialSwiplets()
    private(set) var isLoadingOfficialSwiplets = false
    @PerceptionIgnored private var manifests: [String: LibSwiptSwipletManifest] = [:]
    @PerceptionIgnored private var officialSwipletsChecked: Date?
    private var checked: [String: Date] = [:]

    func reload() {
        let swiplets = Platform.shared.swiplets()
        manifests = Dictionary(uniqueKeysWithValues: swiplets.compactMap { swiplet in swiplet.manifest.map { (swiplet.id_, $0) } })
        directories = Dictionary(uniqueKeysWithValues: swiplets.map { ($0.id_, URL(fileURLWithPath: $0.directory, isDirectory: true)) })
        titles = manifests.mapValues { manifest in
            let title = Self.preferredName(manifest)
            return title.isEmpty ? manifest.id_ : title
        }
        versions = manifests.mapValues(\.version)
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
        official = Set(manifests.keys.filter { Platform.shared.attribute(LibSwiptSwipletAttributeOrigin, of: $0) == LibSwiptSwipletOriginOfficial })
        updatable = Set(manifests.filter { !$0.value.version.isEmpty && !$0.value.updateURL.isEmpty }.keys).subtracting(official)
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

    func assetsDirectory(of id: String) -> URL? {
        directories[id]?.appendingPathComponent(LibSwiptSwipletAssetsFolder, isDirectory: true)
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
            try Platform.shared.setAttribute(LibSwiptSwipletAttributeETag, download.etag, of: id)
        }
    }

    @available(iOS 27, *)
    func open(_ picked: URL) async throws -> SwipletPreview {
        let file = try Self.temporaryFile()
        do {
            try await Task.detached(priority: .userInitiated) {
                try picked.withPickedFile { try FileManager.default.copyItem(at: $0, to: file) }
            }.value
            guard let manifest = try Self.manifest(of: file) else { throw MessageError(String(localized: "The file is not a swiplet.")) }
            let title = Self.preferredName(manifest)
            return SwipletPreview(
                file: file, id: manifest.id_, title: title.isEmpty ? manifest.id_ : title, version: manifest.version,
                icon: SwipletIcon(color: manifest.color, symbol: manifest.symbol))
        } catch {
            Self.discard(file)
            throw error
        }
    }

    @available(iOS 27, *)
    func importSwiplet(_ preview: SwipletPreview) async throws {
        defer {
            Self.discard(preview.file)
            reload()
        }
        _ = try await Platform.shared.installSwiplet(preview.file)
    }

    func discard(_ preview: SwipletPreview) {
        Self.discard(preview.file)
    }

    @available(iOS 27, *)
    func loadOfficialSwiplets(force: Bool = false) async throws {
        if !force, let last = officialSwipletsChecked, Date.now.timeIntervalSince(last) < Self.updateInterval {
            return
        }
        isLoadingOfficialSwiplets = true
        defer { isLoadingOfficialSwiplets = false }
        var request = URLRequest(url: Self.officialSource)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = UserDefaults.standard.string(forKey: Self.officialSourceETagKey), !officialSwiplets.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MessageError(String(localized: "The official source sent an unexpected response.")) }
        if response.statusCode == 304 {
            officialSwipletsChecked = .now
            return
        }
        guard response.statusCode == 200 else { throw MessageError(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)) }
        officialSwiplets = try JSONDecoder().decode(OfficialSource.self, from: data).swiplets
        officialSwipletsChecked = .now
        try? data.write(to: Self.officialSourceCache, options: .atomic)
        UserDefaults.standard.set(response.value(forHTTPHeaderField: "ETag"), forKey: Self.officialSourceETagKey)
    }

    func hasNewerOfficial(_ swiplet: OfficialSwiplet) -> Bool {
        guard let local = manifests[swiplet.id] else { return false }
        if swiplet.versionCode > 0, local.versionCode > 0 {
            return swiplet.versionCode > local.versionCode
        }
        return !swiplet.version.isEmpty && swiplet.version != local.version
    }

    @available(iOS 27, *)
    func installOfficial(_ swiplet: OfficialSwiplet) async throws {
        updating.insert(swiplet.id)
        defer {
            updating.remove(swiplet.id)
            reload()
        }
        let file = try Self.temporaryFile()
        defer { Self.discard(file) }
        guard let link = URL(string: swiplet.url, relativeTo: Self.officialSource)?.absoluteURL, link.scheme == "https" || link.scheme == "http" else {
            throw MessageError(String(localized: "The official source lists an invalid address."))
        }
        let status = try await Self.download(link, to: file)
        guard status == 200 else { throw MessageError(HTTPURLResponse.localizedString(forStatusCode: status)) }
        if !swiplet.sha256.isEmpty {
            let digest = try await Task.detached(priority: .userInitiated) { try Self.sha256(of: file) }.value
            guard digest == swiplet.sha256.lowercased() else { throw MessageError(String(localized: "The download doesn’t match the official source.")) }
        }
        guard try Self.manifest(of: file)?.id_ == swiplet.id else { throw MessageError(String(localized: "The download is a different swiplet.")) }
        let id = try await Platform.shared.installSwiplet(file)
        try Platform.shared.setAttribute(LibSwiptSwipletAttributeOrigin, LibSwiptSwipletOriginOfficial, of: id)
    }

    @available(iOS 27, *)
    func checkForUpdates(of ids: [String]) async {
        if ids.contains(where: official.contains) {
            _ = try? await updateOfficial(force: false)
        }
        for id in ids where updatable.contains(id) {
            if let last = checked[id], Date.now.timeIntervalSince(last) < Self.updateInterval {
                continue
            }
            _ = try? await checkForUpdate(of: id)
        }
    }

    @available(iOS 27, *)
    @discardableResult
    func checkForUpdate(of id: String) async throws -> Bool {
        if official.contains(id) {
            return try await updateOfficial(force: true).contains(id)
        }
        checked[id] = .now
        guard let local = manifests[id], !local.version.isEmpty, !local.updateURL.isEmpty else { return false }
        let download = try await Self.download(
            local.updateURL, etag: Platform.shared.attribute(LibSwiptSwipletAttributeETag, of: id), version: local.version, versionCode: local.versionCode, id: id)
        guard Self.isNewer(download, than: local) else {
            Self.discard(download.file)
            if !download.etag.isEmpty {
                try Platform.shared.setAttribute(LibSwiptSwipletAttributeETag, download.etag, of: id)
            }
            return false
        }
        guard download.id == id else {
            Self.discard(download.file)
            throw MessageError(String(localized: "The update is a different swiplet."))
        }
        if let previous = updates[id] {
            Self.discard(previous.file)
        }
        updates[id] = SwipletUpdate(id: id, file: download.file, version: download.version, etag: download.etag)
        return true
    }

    @available(iOS 27, *)
    private func updateOfficial(force: Bool) async throws -> Set<String> {
        try await loadOfficialSwiplets(force: force)
        var updated: Set<String> = []
        for swiplet in officialSwiplets where official.contains(swiplet.id) && hasNewerOfficial(swiplet) {
            try await installOfficial(swiplet)
            updated.insert(swiplet.id)
        }
        return updated
    }

    @available(iOS 27, *)
    func applyUpdate(_ update: SwipletUpdate) async throws {
        updating.insert(update.id)
        defer { updating.remove(update.id) }
        _ = try await Platform.shared.installSwiplet(update.file)
        try Platform.shared.setAttribute(LibSwiptSwipletAttributeETag, update.etag, of: update.id)
        Self.discard(update.file)
        updates[update.id] = nil
        reload()
    }

    nonisolated private static let updateInterval: TimeInterval = 60 * 60
    nonisolated private static let officialSourceETagKey = "officialSourceETag"
    nonisolated private static let officialSourceCache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OfficialSwiplets.json")

    nonisolated private static func cachedOfficialSwiplets() -> [OfficialSwiplet] {
        guard let data = try? Data(contentsOf: officialSourceCache) else { return [] }
        return (try? JSONDecoder().decode(OfficialSource.self, from: data).swiplets) ?? []
    }

    nonisolated private static func isNewer(_ download: SwipletDownload, than local: LibSwiptSwipletManifest) -> Bool {
        if download.versionCode > 0, local.versionCode > 0 {
            return download.versionCode > local.versionCode
        }
        return !download.version.isEmpty && download.version != local.version
    }

    nonisolated private static func download(_ link: String, etag: String = "", version: String = "", versionCode: Int64 = 0, id: String = "") async throws -> SwipletDownload {
        let file = try temporaryFile()
        let downloader = UncheckedSendable(value: LibSwiptNewSwipletDownloader()!)
        do {
            return try await withTaskCancellationHandler {
                try await blocking {
                    let download = downloader.value.download(link, destination: file.path, etag: etag, version: version, versionCode: versionCode, id_: id)!
                    switch download.errorCode {
                    case LibSwiptSwipletErrorNone:
                        let declared = FileManager.default.fileExists(atPath: file.path) ? (try? manifest(of: file))?.updateURL ?? "" : ""
                        return SwipletDownload(
                            file: file, url: download.url, etag: download.entityTag, id: download.id_, version: download.version,
                            versionCode: download.versionCode, updateURL: declared)
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

    nonisolated private static func download(_ link: URL, to file: URL) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.downloadTask(with: link) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location, let response = response as? HTTPURLResponse else {
                    continuation.resume(throwing: MessageError(String(localized: "The official source sent an unexpected response.")))
                    return
                }
                continuation.resume(with: Result { try FileManager.default.moveItem(at: location, to: file) }.map { response.statusCode })
            }
            .resume()
        }
    }

    nonisolated private static func manifest(of file: URL) throws -> LibSwiptSwipletManifest? {
        var error: NSError?
        let manifest = LibSwiptReadSwipletManifest(file.path, &error)
        if let error { throw error }
        return manifest
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    nonisolated private static func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("swiplet")
    }

    @available(iOS 27, *)
    func export(_ id: String) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(id).appendingPathExtension(for: .swiplet)
        try await Platform.shared.exportSwiplet(id, to: file)
        return file
    }

    nonisolated static func preferredName(_ name: String, localized: [String: String]) -> String {
        let languages = ["en"] + localized.keys.filter { $0 != "en" }.sorted()
        let preferred = Bundle.preferredLocalizations(from: languages, forPreferences: Locale.preferredLanguages).first ?? "en"
        return localized[preferred] ?? name
    }

    nonisolated private static func preferredName(_ names: LibSwiptSwipletManifest) -> String {
        var localized: [String: String] = [:]
        var name = ""
        for index in 0..<names.len() {
            let language = names.language(index)
            if language.isEmpty {
                name = names.name(index)
            } else {
                localized[language] = names.name(index)
            }
        }
        return preferredName(name, localized: localized)
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
        FileRepresentation(exportedContentType: .swiplet) { swiplet in
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

nonisolated struct SwipletPreview: Identifiable, Sendable {
    let file: URL
    let id: String
    let title: String
    let version: String
    let icon: SwipletIcon
}

nonisolated struct OfficialSwiplet: Decodable, Identifiable, Sendable {
    struct Icon: Decodable, Sendable {
        let color: String
        let symbol: String
    }

    let id: String
    let name: String
    let localizedNames: [String: String]
    let description: String
    let version: String
    let versionCode: Int64
    let icon: Icon?
    let url: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case id, name, localizedNames, description, version, versionCode, icon, url, sha256
    }

    var title: String {
        SwipletStore.preferredName(name, localized: localizedNames)
    }

    var swipletIcon: SwipletIcon {
        icon.map { SwipletIcon(color: $0.color, symbol: $0.symbol) } ?? .default
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        localizedNames = try container.decodeIfPresent([String: String].self, forKey: .localizedNames) ?? [:]
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        versionCode = try container.decodeIfPresent(Int64.self, forKey: .versionCode) ?? 0
        icon = try? container.decodeIfPresent(Icon.self, forKey: .icon)
        url = try container.decode(String.self, forKey: .url)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) ?? ""
    }
}

nonisolated private struct OfficialSource: Decodable {
    let swiplets: [OfficialSwiplet]
}

nonisolated private struct SwipletDownload: Sendable {
    let file: URL
    let url: String
    let etag: String
    let id: String
    let version: String
    let versionCode: Int64
    let updateURL: String
}
