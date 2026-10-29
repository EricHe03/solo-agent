import CoreTransferable
import Foundation
import LibSwipt
import Perception
import UniformTypeIdentifiers

@Perceptible
final class WorkflowStore {
    static let shared = WorkflowStore()
    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Workflows", isDirectory: true)

    private(set) var names: [String] = []
    private(set) var icons: [String: WorkflowIcon] = [:]
    private(set) var updatable: Set<String> = []
    private(set) var updates: [String: WorkflowUpdate] = [:]
    private(set) var updating: Set<String> = []
    private var checked: [String: Date] = [:]
    private var runs: [String: Task<Result<ScriptOutput, any Error>?, Never>] = [:]
    private var waiting: Set<String> = []

    func reload() {
        names = ((try? FileManager.default.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") && Self.isDirectory(Self.directory.appendingPathComponent($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        icons = Dictionary(uniqueKeysWithValues: names.map { ($0, WorkflowIcon.load(from: Self.url(of: $0))) })
        updatable = Set(names.filter { name in
            guard let header = try? Self.header(of: name) else { return false }
            return !header.version.isEmpty && !header.updateURL.isEmpty
        })
    }

    func isRunning(_ name: String) -> Bool {
        runs[name] != nil
    }

    func isWaiting(_ name: String) -> Bool {
        waiting.contains(name)
    }

    @available(iOS 27, *)
    @discardableResult
    func run(_ name: String) async -> Result<ScriptOutput, any Error>? {
        let run =
            runs[name]
            ?? Task {
                let result: Result<ScriptOutput, any Error>?
                do {
                    result = .success(
                        try await ServerController.shared.runWorkflow(name, dialogs: .app) {
                            Task { @MainActor in
                                if self.runs[name] != nil {
                                    self.waiting.insert(name)
                                }
                            }
                        })
                } catch is CancellationError {
                    result = nil
                } catch {
                    result = .failure(error)
                }
                waiting.remove(name)
                guard runs.removeValue(forKey: name) != nil else { return nil }
                return Task.isCancelled ? nil : result
            }
        runs[name] = run
        return await run.value
    }

    func stop(_ name: String) {
        runs[name]?.cancel()
    }

    @available(iOS 27, *)
    func importWorkflow(from picked: URL) async throws {
        defer { reload() }
        try await Task.detached(priority: .userInitiated) {
            try picked.withPickedFile { file in
                try Self.install(file, suggestedName: picked.deletingPathExtension().lastPathComponent, source: nil, etag: "")
            }
        }.value
    }

    @available(iOS 27, *)
    func importWorkflow(downloadingFrom link: String) async throws {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let download = try await Self.download(link)
        defer {
            Self.discard(download.file)
            reload()
        }
        try await Task.detached(priority: .userInitiated) {
            try Self.install(download.file, suggestedName: download.name, source: link, etag: download.etag)
        }.value
    }

    @available(iOS 27, *)
    func checkForUpdates(of names: [String]) async {
        for name in names where updatable.contains(name) {
            if let last = checked[name], Date.now.timeIntervalSince(last) < Self.updateInterval {
                continue
            }
            try? await checkForUpdate(of: name)
        }
    }

    @available(iOS 27, *)
    func checkForUpdate(of name: String) async throws {
        checked[name] = .now
        let directory = Self.url(of: name)
        let local = try Self.header(of: name)
        guard !local.version.isEmpty, !local.updateURL.isEmpty else { return }
        let download = try await Self.download(local.updateURL, etag: LibSwiptWorkflowETag(directory.path), version: local.version)
        var error: NSError?
        if download.version == local.version {
            LibSwiptSetWorkflowETag(directory.path, download.etag, &error)
        }
        guard error == nil, !download.version.isEmpty, download.version != local.version else {
            Self.discard(download.file)
            if let error { throw error }
            return
        }
        let update = WorkflowUpdate(name: name, file: download.file, version: download.version, etag: download.etag)
        if download.url.hasPrefix(Self.trustedPrefix), (try? await applyUpdate(update)) != nil {
            return
        }
        if let previous = updates[name] {
            Self.discard(previous.file)
        }
        updates[name] = update
    }

    @available(iOS 27, *)
    func applyUpdate(_ update: WorkflowUpdate) async throws {
        updating.insert(update.name)
        defer { updating.remove(update.name) }
        let directory = Self.url(of: update.name)
        try await Task.detached(priority: .userInitiated) {
            var error: NSError?
            LibSwiptUpdateWorkflow(directory.path, update.file.path, &error)
            if let error { throw error }
            LibSwiptSetWorkflowETag(directory.path, update.etag, &error)
            if let error { throw error }
        }.value
        Self.discard(update.file)
        updates[update.name] = nil
        reload()
        if let run = runs[update.name] {
            run.cancel()
            _ = await run.value
            Task { await self.run(update.name) }
        }
    }

    nonisolated private static let updateInterval: TimeInterval = 60 * 60

    nonisolated private static func header(of name: String) throws -> LibSwiptWorkflowHeader {
        var error: NSError?
        let header = LibSwiptLoadWorkflowHeader(url(of: name).path, &error)
        if let error { throw error }
        guard let header else { throw MessageError(String(localized: "Can’t Update the Workflow")) }
        return header
    }

    nonisolated private static func download(_ link: String, etag: String = "", version: String = "") async throws -> (file: URL, url: String, etag: String, name: String, version: String) {
        let file = try temporaryFile()
        let downloader = UncheckedSendable(value: LibSwiptNewWorkflowDownloader()!)
        do {
            return try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    let download = downloader.value.download(link, destination: file.path, etag: etag, version: version)!
                    switch download.errorCode {
                    case LibSwiptWorkflowErrorNone:
                        return (file, download.url, download.entityTag, download.name, download.version)
                    case LibSwiptWorkflowErrorTimeout:
                        throw MessageError(String(localized: "The connection timed out."))
                    default:
                        throw MessageError(download.errorMessage)
                    }
                }.value
            } onCancel: {
                downloader.value.cancel()
            }
        } catch {
            discard(file)
            throw error
        }
    }

    nonisolated private static func discard(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    nonisolated private static let trustedPrefix = "https://raw.githubusercontent.com/nekohasekai/open-screen-sharing/"

    nonisolated private static func temporaryFile() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("workflow")
    }

    @available(iOS 27, *)
    nonisolated private static func install(_ file: URL, suggestedName: String, source: String?, etag: String) throws {
        var error: NSError?
        let header = LibSwiptReadWorkflowHeader(file.path, &error)
        if let error { throw error }
        let name = [preferredName(header), suggestedName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: isValid)
        let directory = url(of: unused(name ?? String(localized: "Workflow")))
        LibSwiptImportWorkflow(directory.path, file.path, source ?? "", &error)
        if let error { throw error }
        let declared = header?.updateURL ?? ""
        if let source, declared.isEmpty || declared == source {
            LibSwiptSetWorkflowETag(directory.path, etag, &error)
            if let error { throw error }
        }
    }

    nonisolated static func isSingleFile(_ name: String) -> Bool {
        LibSwiptIsSingleFileWorkflow(url(of: name).path)
    }

    @available(iOS 27, *)
    nonisolated static func export(_ name: String, as type: UTType) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name).appendingPathExtension(for: type)
        var error: NSError?
        let header = LibSwiptLoadWorkflowHeader(url(of: name).path, &error)
        if let error { throw error }
        LibSwiptExportWorkflow(url(of: name).path, file.path, preferredName(header) == name, &error)
        if let error { throw error }
        return file
    }

    @available(iOS 27, *)
    nonisolated private static func preferredName(_ names: LibSwiptWorkflowHeader?) -> String {
        guard let names else { return "" }
        var name = ""
        var localized: [(language: Locale.Language, name: String)] = []
        for index in 0..<names.len() {
            if names.language(index).isEmpty {
                name = names.name(index)
            } else {
                localized.append((Locale.Language(identifier: Locale.Language(identifier: names.language(index)).maximalIdentifier), names.name(index)))
            }
        }
        for preference in Locale.preferredLanguages {
            let wanted = Locale.Language(identifier: Locale.Language(identifier: preference).maximalIdentifier)
            if let match = localized.first(where: { $0.language.languageCode == wanted.languageCode && $0.language.script == wanted.script }) {
                return match.name
            }
        }
        return name
    }

    func rename(_ name: String, to newName: String) throws -> String {
        let newName = try Self.available(newName)
        defer { reload() }
        forgetUpdate(of: name)
        try FileManager.default.moveItem(at: Self.url(of: name), to: Self.url(of: newName))
        return newName
    }

    @available(iOS 27, *)
    @discardableResult
    func duplicate(_ name: String) throws -> String {
        let copy = Self.unused(name)
        defer { reload() }
        let source = Self.url(of: name)
        let destination = Self.url(of: copy)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        do {
            for entry in try FileManager.default.contentsOfDirectory(atPath: source.path) where !entry.hasPrefix(".") {
                try FileManager.default.copyItem(at: source.appendingPathComponent(entry), to: destination.appendingPathComponent(entry))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return copy
    }

    private func forgetUpdate(of name: String) {
        if let update = updates.removeValue(forKey: name) {
            Self.discard(update.file)
        }
        checked[name] = nil
    }

    func setIcon(_ icon: WorkflowIcon, for name: String) throws {
        try icon.save(to: Self.url(of: name))
        icons[name] = icon
    }

    func remove(_ name: String) throws {
        defer { reload() }
        forgetUpdate(of: name)
        runs.removeValue(forKey: name)?.cancel()
        try FileManager.default.removeItem(at: Self.url(of: name))
    }

    nonisolated static func url(of workflow: String) -> URL {
        directory.appendingPathComponent(workflow, isDirectory: true)
    }

    @available(iOS 27, *)
    nonisolated private static func unused(_ name: String) -> String {
        guard FileManager.default.fileExists(atPath: url(of: name).path) else { return name }
        let base = name.wholeMatch(of: /(.+) \d+/).map { String($0.1) } ?? name
        var number = 2
        while FileManager.default.fileExists(atPath: url(of: "\(base) \(number)").path) {
            number += 1
        }
        return "\(base) \(number)"
    }

    nonisolated private static func isValid(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }

    nonisolated private static func available(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValid(name) else {
            throw MessageError(String(localized: "A workflow name can’t be empty, start with a period, or contain a slash."))
        }
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else {
            throw MessageError(String(localized: "There’s already a workflow named “\(name)”."))
        }
        return name
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@available(iOS 27, *)
nonisolated struct WorkflowFile: Transferable {
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .javaScript) { workflow in
            SentTransferredFile(try WorkflowStore.export(workflow.name, as: .javaScript))
        }
        .exportingCondition { WorkflowStore.isSingleFile($0.name) }
        FileRepresentation(exportedContentType: .zip) { workflow in
            SentTransferredFile(try WorkflowStore.export(workflow.name, as: .zip))
        }
        .exportingCondition { !WorkflowStore.isSingleFile($0.name) }
    }
}

nonisolated struct WorkflowUpdate: Sendable {
    let name: String
    let file: URL
    let version: String
    let etag: String
}
