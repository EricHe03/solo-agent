import Foundation
import LibSwipt
import Perception
import UIKit
import UserNotifications
import os

nonisolated struct ScriptOutput: Sendable {
    enum Part: Sendable {
        case text(String)
        case image(Data)
    }

    var parts: [Part]

    var text: String {
        parts.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
    }

    var images: [Data] {
        parts.compactMap { if case .image(let data) = $0 { data } else { nil } }
    }
}

@Perceptible
final class ServerController {
    static let shared = ServerController()
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "server")
    nonisolated static let problemNotification = "server-problem"

    enum Phase: Equatable {
        case stopped
        case starting
        case connecting
        case preparing
        case running
        case failed(ServerProblem)

        var isActive: Bool {
            switch self {
            case .stopped, .failed: false
            case .starting, .connecting, .preparing, .running: true
            }
        }

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
    }

    private(set) var phase: Phase = .stopped {
        didSet {
            guard phase != oldValue else { return }
            phaseChanged()
        }
    }

    private(set) var connectionProblem: ServerProblem?
    private(set) var tunnelFound: Bool?
    private(set) var tunnelThroughLocalNetwork = false

    let remotePairing = RemotePairingBrowser()
    let pairingSession = PairingSession()
    @PerceptionIgnored private lazy var location: BackgroundLocation = {
        let location = BackgroundLocation()
        location.onUpdatingChange = { [weak self] in
            self?.updateIdleTimer()
        }
        location.onDenied = { [weak self] in
            self?.fail(ServerProblem(kind: .locationDenied, message: ""))
        }
        return location
    }()
    @PerceptionIgnored private lazy var audio: BackgroundAudio = {
        let audio = BackgroundAudio()
        audio.onPlayingChange = { [weak self] in
            self?.updateIdleTimer()
        }
        audio.onFailure = { [weak self] error in
            self?.fail(ServerProblem(kind: .other, message: error.localizedDescription))
        }
        return audio
    }()

    @PerceptionIgnored private var server: LibSwiptDeviceServer?
    @PerceptionIgnored private var generation = 0
    @PerceptionIgnored private var runs = 0
    @PerceptionIgnored private var dialogs: [Int64: Task<Void, Never>] = [:]
    @PerceptionIgnored private var startTask: Task<Void, Never>?
    @PerceptionIgnored private var closingTask: Task<Void, Never>?
    @PerceptionIgnored private var probeTask: Task<Void, Never>?
    @PerceptionIgnored private var probeClients = 0
    @PerceptionIgnored private var isBrowsing = false
    nonisolated private static let queue = DispatchQueue(label: "io.nekohasekai.swipt.server", qos: .userInitiated)

    private var settings: ServerSettings { .shared }
    private var pairing: PairingStore { .shared }

    init() {
        remotePairing.onPortChange = { [weak self] port in
            self?.server?.setRemotePairingPort(Int32(port))
        }
    }

    var isActive: Bool { phase.isActive }

    var isMCPActive: Bool { phase.isActive && settings.isMCPEnabled }

    var canStartMCP: Bool { canStart && settings.isMCPComplete }

    var startProblem: String? {
        if !pairing.isPaired {
            return String(localized: "Pair and import the Developer Disk Image in Settings › Services first.")
        }
        if settings.autoUnlockProblem != nil {
            return String(localized: "Check Automatic Unlock in Settings › Services.")
        }
        if DiskImageStore.shared.isImporting {
            return String(localized: "The Developer Disk Image is still importing.")
        }
        return nil
    }

    private var canStart: Bool {
        startProblem == nil && tunnelFound != false
    }

    func startProbing() {
        probeClients += 1
        guard probeTask == nil else { return }
        probeTask = Task {
            while !Task.isCancelled {
                let throughLocalNetwork: Bool
                if phase.isActive {
                    throughLocalNetwork = server?.loopbackAddress()?.localNetwork ?? false
                } else {
                    let port = remotePairing.port ?? 0
                    let probe = UncheckedSendable(value: LibSwiptNewLoopbackProbe(Int32(port))!)
                    let result = await withTaskCancellationHandler {
                        await Task.detached(priority: .utility) {
                            do {
                                let loopback = try probe.value.run()
                                return (found: true, localNetwork: loopback.localNetwork)
                            } catch {
                                return (found: false, localNetwork: false)
                            }
                        }.value
                    } onCancel: {
                        probe.value.cancel()
                    }
                    guard !Task.isCancelled else { return }
                    if tunnelFound != result.found {
                        tunnelFound = result.found
                    }
                    throughLocalNetwork = result.localNetwork
                }
                if tunnelThroughLocalNetwork != throughLocalNetwork {
                    tunnelThroughLocalNetwork = throughLocalNetwork
                }
                try? await Task.sleep(seconds: 2)
            }
        }
    }

    func stopProbing() {
        probeClients = max(0, probeClients - 1)
        guard probeClients == 0 else { return }
        probeTask?.cancel()
        probeTask = nil
    }

    var name: String {
        if let name = pairing.device?.name, !name.isEmpty {
            return name
        }
        return UIDevice.current.name
    }

    func resume() {
        guard settings.isMCPEnabled else { return }
        if canStartMCP {
            start()
        } else {
            settings.isMCPEnabled = false
        }
    }

    func setMCP(_ enabled: Bool) {
        settings.isMCPEnabled = enabled
        if enabled {
            start()
        } else if runs == 0 {
            stop()
        }
        if let server {
            let options = UncheckedSendable(value: enabled ? mcpOptions : nil)
            configure(server) { try $0.setMCP(options.value) }
        }
    }

    func dismissFailure() {
        if case .failed = phase {
            phase = .stopped
        }
    }

    func waitUntilRunning() async throws {
        while true {
            switch phase {
            case .running:
                return
            case .stopped:
                throw MessageError(String(localized: "The server stopped."))
            case .failed(let problem):
                throw problem
            case .connecting:
                if let connectionProblem {
                    throw connectionProblem
                }
            case .starting, .preparing:
                break
            }
            let (changes, continuation) = AsyncStream<Void>.makeStream()
            withPerceptionTracking {
                _ = phase
                _ = connectionProblem
            } onChange: {
                continuation.finish()
            }
            for await _ in changes {}
            try Task.checkCancellation()
        }
    }

    @available(iOS 27, *)
    func runScript(_ code: String, dialogs: DialogHost) async throws -> ScriptOutput {
        try await run(dialogs: dialogs, waiting: {}) { $0.newScript(code, observer: $1, showsInApp: $2)! }
    }

    @available(iOS 27, *)
    func runWorkflow(_ name: String, dialogs: DialogHost, waiting: @escaping @Sendable () -> Void = {}) async throws -> ScriptOutput {
        try await run(dialogs: dialogs, waiting: waiting) { $0.newWorkflowRun(name, observer: $1, showsInApp: $2)! }
    }

    @available(iOS 27, *)
    private func run(
        dialogs: DialogHost, waiting: @escaping @Sendable () -> Void, _ make: (LibSwiptDeviceServer, ScriptEvents, Bool) -> LibSwiptScript
    ) async throws -> ScriptOutput {
        if !phase.isActive, let startProblem {
            throw MessageError(startProblem)
        }
        runs += 1
        defer {
            runs -= 1
            if runs == 0, !settings.isMCPEnabled {
                stop()
            }
        }
        start()
        try await waitUntilRunning()
        guard let server else { throw MessageError(String(localized: "The server stopped.")) }
        let (requests, delivery) = AsyncStream<String>.makeStream()
        defer { delivery.finish() }
        let dialog: DialogPresenter
        switch dialogs {
        case .app:
            dialog = { try await WorkflowDialogs.shared.present($0) }
        case .intent(let present):
            dialog = present
        }
        let showsInApp = if case .app = dialogs { true } else { false }
        let script = UncheckedSendable(value: make(server, ScriptEvents(waiting: waiting) { delivery.yield($0) }, showsInApp))
        return try await withThrowingTaskGroup(of: ScriptOutput?.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        let output = try script.value.run()
                        return ScriptOutput(parts: (0..<output.count()).map { index in
                            output.image(index).map(ScriptOutput.Part.image) ?? .text(output.text(index))
                        })
                    }.value
                } onCancel: {
                    script.value.cancel()
                }
            }
            group.addTask {
                for await request in requests {
                    let answer = try await dialog(try JSONDecoder().decode(DialogRequest.self, from: Data(request.utf8)))
                    script.value.answer(answer.json)
                }
                return nil
            }
            for try await output in group {
                if let output {
                    group.cancelAll()
                    return output
                }
            }
            throw CancellationError()
        }
    }

    private func handleDialog(_ dialogID: Int64, request: String?) {
        guard let request else {
            dialogs.removeValue(forKey: dialogID)?.cancel()
            return
        }
        guard let server else { return }
        let box = UncheckedSendable(value: server)
        guard #available(iOS 27, *), let decoded = try? JSONDecoder().decode(DialogRequest.self, from: Data(request.utf8)) else {
            box.value.dismissDialog(dialogID)
            return
        }
        dialogs[dialogID] = Task {
            do {
                let answer = try await WorkflowDialogs.shared.present(decoded)
                box.value.answerDialog(dialogID, answer: answer.json)
            } catch {
                box.value.dismissDialog(dialogID)
            }
            dialogs.removeValue(forKey: dialogID)
        }
    }

    func resetScript() async throws {
        guard let server else { return }
        let box = UncheckedSendable(value: server)
        try await Task.detached(priority: .userInitiated) { try box.value.resetScript() }.value
    }

    private func start() {
        guard !phase.isActive, let record = pairing.record else { return }
        if settings.runsInBackground, settings.backgroundMode == .location, location.isDenied {
            fail(ServerProblem(kind: .locationDenied, message: ""))
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Self.logger.error("Request notification authorization: \(error.localizedDescription, privacy: .public)")
            }
        }
        generation += 1
        let generation = generation
        phase = .starting
        startTask = Task {
            guard generation == self.generation else { return }
            await launch(record: record, generation: generation)
        }
    }

    private func stop() {
        guard phase.isActive else { return }
        generation += 1
        startTask?.cancel()
        startTask = nil
        closeServer()
        phase = .stopped
    }

    private func launch(record: Data, generation: Int) async {
        await closingTask?.value
        guard generation == self.generation else { return }
        let options = LibSwiptDeviceServerOptions()
        options.pairingRecord = record
        options.remotePairingPort = Int32(remotePairing.port ?? 0)
        options.autoUnlockPasscode = settings.autoUnlocks ? settings.autoUnlockPasscode : ""
        options.autoUnlockPasscodeType = settings.autoUnlockPasscodeType.rawValue
        options.workflowDirectory = WorkflowStore.directory.path
        options.appBundleID = Bundle.main.bundleIdentifier ?? ""
        do {
            options.diskImageDirectory = try DiskImageStore.directory.get().path
        } catch {
            fail(ServerProblem(kind: .diskImage, message: error.localizedDescription))
            return
        }
        let events = DeviceServerEvents(
            state: { [weak self] change in
                DispatchQueue.main.async { self?.handle(change, generation: generation) }
            },
            dialog: { [weak self] dialogID, request in
                DispatchQueue.main.async { self?.handleDialog(dialogID, request: request) }
            },
            backdrop: { image in
                DispatchQueue.main.sync {
                    if #available(iOS 27, *) {
                        WorkflowDialogs.shared.showBackdrop(image)
                    }
                }
            })
        let request = UncheckedSendable(value: options)
        let result = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(returning: Self.makeServer(request.value, events: events))
            }
        }
        switch result {
        case .success(let box):
            guard generation == self.generation else {
                Self.queue.async {
                    do { try box.value.close() }
                    catch { Self.logger.error("Close unused server: \(error.localizedDescription, privacy: .public)") }
                }
                return
            }
            if let port = remotePairing.port, Int32(port) != options.remotePairingPort {
                box.value.setRemotePairingPort(Int32(port))
            }
            do {
                try box.value.setMCP(settings.isMCPEnabled ? mcpOptions : nil)
                try box.value.start()
            } catch {
                Self.queue.async {
                    do { try box.value.close() }
                    catch { Self.logger.error("Close unused server: \(error.localizedDescription, privacy: .public)") }
                }
                fail(ServerProblem(kind: .other, message: error.localizedDescription))
                return
            }
            server = box.value
        case .failure(let error):
            guard generation == self.generation else { return }
            fail(ServerProblem(kind: .other, message: error.message))
        }
    }

    private var mcpOptions: LibSwiptMCPOptions {
        let options = LibSwiptMCPOptions()
        options.port = Int32(settings.mcpPort)
        options.token = settings.mcpAuthenticates ? settings.mcpToken : ""
        return options
    }

    private func configure(_ server: LibSwiptDeviceServer, _ change: @escaping @Sendable (LibSwiptDeviceServer) throws -> Void) {
        let box = UncheckedSendable(value: server)
        let generation = generation
        Self.queue.async { [weak self] in
            do {
                try change(box.value)
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self, generation == self.generation else { return }
                    self.fail(ServerProblem(kind: .other, message: message))
                }
            }
        }
    }

    nonisolated private static func makeServer(
        _ options: LibSwiptDeviceServerOptions, events: DeviceServerEvents
    ) -> Result<UncheckedSendable<LibSwiptDeviceServer>, MessageError> {
        LibSwiptLog.installed
        var error: NSError?
        guard let server = LibSwiptNewDeviceServer(options, events, &error) else {
            return .failure(MessageError(error?.localizedDescription ?? "libswipt returned no server"))
        }
        return .success(UncheckedSendable(value: server))
    }

    private func handle(_ change: DeviceServerStateChange, generation: Int) {
        guard generation == self.generation else { return }
        let problem = change.errorCode == LibSwiptDeviceErrorNone ? nil : ServerProblem(code: change.errorCode, message: change.message)
        connectionProblem = change.state == LibSwiptDeviceServerConnecting ? problem : nil
        switch change.state {
        case LibSwiptDeviceServerConnecting:
            phase = .connecting
        case LibSwiptDeviceServerPreparing:
            phase = .preparing
        case LibSwiptDeviceServerRunning:
            phase = .running
        case LibSwiptDeviceServerFailed:
            fail(problem ?? ServerProblem(kind: .other, message: change.message))
        case LibSwiptDeviceServerStopped:
            self.generation += 1
            server = nil
            settings.isMCPEnabled = false
            phase = problem.map(Phase.failed) ?? .stopped
        default:
            break
        }
    }

    private func fail(_ problem: ServerProblem) {
        settings.isMCPEnabled = false
        generation += 1
        startTask?.cancel()
        startTask = nil
        closeServer()
        phase = .failed(problem)
    }

    private func closeServer() {
        guard let server else { return }
        self.server = nil
        let box = UncheckedSendable(value: server)
        let generation = generation
        closingTask = Task {
            let error: String? = await withCheckedContinuation { continuation in
                Self.queue.async {
                    do {
                        try box.value.close()
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error.localizedDescription)
                    }
                }
            }
            if let error {
                Self.logger.error("Close server: \(error, privacy: .public)")
                if generation == self.generation, self.phase == .stopped {
                    self.phase = .failed(ServerProblem(kind: .other, message: error))
                }
            }
        }
    }

    private func phaseChanged() {
        let notifications = UNUserNotificationCenter.current()
        if case .failed(let problem) = phase {
            let content = UNMutableNotificationContent()
            content.title = problem.title
            content.body = problem.message
            content.sound = .default
            notifications.add(UNNotificationRequest(identifier: Self.problemNotification, content: content, trigger: nil)) { error in
                if let error {
                    Self.logger.error("Post the sharing problem: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            notifications.removeDeliveredNotifications(withIdentifiers: [Self.problemNotification])
        }
        updateBackground()
        setBrowsing(phase.isActive)
    }

    func updateBackground() {
        let mode = phase.isActive && settings.runsInBackground ? settings.backgroundMode : nil
        if mode == .location {
            location.start()
        } else {
            location.stop()
        }
        if mode == .audio {
            audio.start()
        } else {
            audio.stop()
        }
        updateIdleTimer()
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = phase.isActive && !location.isUpdating && !audio.isPlaying
    }

    private func setBrowsing(_ browsing: Bool) {
        guard browsing != isBrowsing else { return }
        isBrowsing = browsing
        if browsing {
            remotePairing.start()
        } else {
            remotePairing.stop()
        }
    }
}
