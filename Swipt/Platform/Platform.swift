import Foundation
import LibSwipt
import Perception
import SwiftUI
import UIKit
import UserNotifications
import dnssd
import os

@Perceptible
final class Platform {
    static let shared = Platform()
    nonisolated static let queue = DispatchQueue(label: "io.nekohasekai.swipt.platform", qos: .userInitiated)
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "platform")

    static var isSupported: Bool {
        guard #available(iOS 27, *) else { return false }
        return !ProcessInfo.processInfo.isiOSAppOnMac
    }

    let device: DeviceConnection
    private var calls = 0

    @PerceptionIgnored private let core: LibSwiptPlatform
    @PerceptionIgnored private lazy var location: BackgroundLocation = {
        let location = BackgroundLocation()
        location.onUpdatingChange = { [weak self] in
            self?.updateIdleTimer()
        }
        location.onDenied = {
            ErrorAlert.shared.report(
                AlertState(
                    title: String(localized: "No Location Access"),
                    actions: [
                        AlertState.Action(label: String(localized: "Open Settings"), role: nil) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        },
                        AlertState.Action(label: String(localized: "OK"), role: .cancel) {},
                    ]))
        }
        return location
    }()
    @PerceptionIgnored private lazy var audio: BackgroundAudio = {
        let audio = BackgroundAudio()
        audio.onPlayingChange = { [weak self] in
            self?.updateIdleTimer()
        }
        audio.onFailure = { error in
            ErrorAlert.shared.report(String(localized: "Couldn’t Run in the Background"), error: error)
        }
        return audio
    }()

    private var cloudflareTunnel: LibSwiptCloudflareTunnel?
    @PerceptionIgnored private var cloudflareGeneration = 0
    @PerceptionIgnored private var cloudflareError: String?
    @PerceptionIgnored private let apiAdvertiser = BonjourAdvertiser()
    @PerceptionIgnored private var advertised: APIAdvertisement?
    @PerceptionIgnored private var dialogs: [Int64: Task<Void, Never>] = [:]
    @PerceptionIgnored private var reportedServices: Set<String> = []
    @PerceptionIgnored private var wasActive = false
    nonisolated private let isAppActive: LockedState<Bool>

    private var background: BackgroundSettings { .shared }
    private var developer: DeveloperSettings { .shared }

    private init() {
        LibSwiptLog.installed
        let options = LibSwiptPlatformOptions()
        options.swipletDirectory = SwipletStore.directory.path
        options.cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path
        options.languages = Locale.preferredLanguages.joined(separator: "\n")
        options.appBundleID = Bundle.main.bundleIdentifier ?? ""
        options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        options.appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let deviceOptions = LibSwiptDeviceOptions()
        deviceOptions.diskImageDirectory = Bundle.main.url(forResource: "DeveloperDiskImage", withExtension: nil)?.path ?? ""
        let isAppActive = LockedState(initialState: false)
        self.isAppActive = isAppActive
        let events = PlatformEvents(
            backdrop: { image in
                DispatchQueue.main.sync {
                    if #available(iOS 27, *) {
                        ScriptDialogs.shared.showBackdrop(image)
                    }
                }
            },
            active: { [isAppActive] in isAppActive.withLock { $0 } })
        let deviceEvents = DeviceEvents()
        let core = LibSwiptNewPlatform(options, events, deviceOptions, deviceEvents, Graphics.shared)!
        self.core = core
        Graphics.shared.attach(core.device()!)
        device = DeviceConnection(core.device()!, events: deviceEvents)
        apiAdvertiser.onFailure = { [weak self] errorCode in
            self?.advertisingFailed(errorCode)
        }
        events.connect { [weak self] event in
            DispatchQueue.main.async { self?.handle(event) }
        }
    }

    var isActive: Bool { developer.isPublishing || calls > 0 || SwipletStore.shared.hasEnabledServices }

    var name: String {
        if let name = PairingStore.shared.device?.name, !name.isEmpty {
            return name
        }
        return UIDevice.current.name
    }

    func start() {
        isAppActive.withLock { $0 = UIApplication.shared.applicationState == .active }
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [isAppActive] _ in
                isAppActive.withLock { $0 = active }
            }
        }
        device.start()
        let box = UncheckedSendable(value: core)
        Self.queue.async {
            do {
                try box.value.start()
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    ErrorAlert.shared.report(AlertState(String(localized: "Couldn’t Start Swipt"), errorMessage: message))
                }
            }
        }
        observeCloudflare()
        observeAPI()
        SwipletStore.shared.reload()
        observeActivity()
    }

    @available(iOS 27, *)
    func callAction(_ swiplet: String, action: String, input: String, caller: String, dialogs: DialogHost) async throws -> String {
        calls += 1
        defer { calls -= 1 }
        let (requests, delivery) = AsyncStream<String>.makeStream()
        defer { delivery.finish() }
        let present: DialogPresenter
        switch dialogs {
        case .app:
            present = { try await ScriptDialogs.shared.present($0) }
        case .intent(let presenter):
            present = presenter
        }
        let showsInApp = if case .app = dialogs { true } else { false }
        let events = ActionEvents { delivery.yield($0) }
        let call = UncheckedSendable(value: core.newActionCall(swiplet, action: action, input: input, caller: caller, observer: events, showsInApp: showsInApp)!)
        let presenting = Task {
            for await request in requests {
                do {
                    let answer = try await present(try JSONDecoder().decode(DialogRequest.self, from: Data(request.utf8)))
                    call.value.answer(answer.json)
                } catch {
                    guard !Task.isCancelled else { return }
                    call.value.dismiss()
                }
            }
        }
        defer { presenting.cancel() }
        return try await withTaskCancellationHandler {
            try await blocking {
                var error: NSError?
                let output = call.value.run(&error)
                if let error { throw error }
                return output
            }
        } onCancel: {
            call.value.cancel()
        }
    }

    func serviceState(of swiplet: String) -> SwipletService {
        guard let state = core.serviceState(swiplet) else { return SwipletService() }
        return SwipletService(enabled: state.enabled, status: state.status, error: state.error, since: state.since)
    }

    func setServiceEnabled(_ swiplet: String, _ enabled: Bool) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.setServiceEnabled(swiplet, enabled: enabled) }
    }

    func logSwiplet(_ swiplet: String, level: Int32, message: String) {
        core.logSwiplet(swiplet, level: level, message: message)
    }

    func statSwipletFile(_ swiplet: String, root: String, path: String) async throws -> SwipletFileInfo {
        let box = UncheckedSendable(value: core)
        return try await blocking { SwipletFileInfo(try box.value.statSwipletFile(swiplet, root: root, path: path)) }
    }

    func listSwipletFiles(_ swiplet: String, root: String, path: String) async throws -> [SwipletFileInfo] {
        let box = UncheckedSendable(value: core)
        return try await blocking {
            let list = try box.value.listSwipletFiles(swiplet, root: root, path: path)
            return (0..<list.len()).compactMap { list.get($0) }.map(SwipletFileInfo.init)
        }
    }

    func readSwipletFile(_ swiplet: String, root: String, path: String) async throws -> Data {
        let box = UncheckedSendable(value: core)
        return try await blocking { try box.value.readSwipletFile(swiplet, root: root, path: path) }
    }

    func writeSwipletFile(_ swiplet: String, root: String, path: String, data: Data) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.writeSwipletFile(swiplet, root: root, path: path, data: data) }
    }

    func makeSwipletDirectory(_ swiplet: String, root: String, path: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.makeSwipletDirectory(swiplet, root: root, path: path) }
    }

    func removeSwipletFile(_ swiplet: String, root: String, path: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.removeSwipletFile(swiplet, root: root, path: path) }
    }

    func copySwipletFile(_ swiplet: String, root: String, from: String, toRoot: String, to: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.copySwipletFile(swiplet, root: root, from: from, toRoot: toRoot, to: to) }
    }

    func moveSwipletFile(_ swiplet: String, root: String, from: String, toRoot: String, to: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.moveSwipletFile(swiplet, root: root, from: from, toRoot: toRoot, to: to) }
    }

    func swiplets() -> [LibSwiptSwipletInfo] {
        guard let list = core.swiplets() else { return [] }
        return (0..<list.len()).compactMap { list.get($0) }
    }

    func installSwiplet(_ file: URL) async throws -> String {
        let box = UncheckedSendable(value: core)
        return try await blocking { try Self.install(file, into: box.value) }
    }

    func installSwiplet(picked file: URL) async throws -> String {
        let box = UncheckedSendable(value: core)
        return try await blocking { try file.withPickedFile { try Self.install($0, into: box.value) } }
    }

    nonisolated private static func install(_ file: URL, into platform: LibSwiptPlatform) throws -> String {
        var error: NSError?
        let id = platform.installSwiplet(file.path, error: &error)
        if let error { throw error }
        return id
    }

    func removeSwiplet(_ swiplet: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.removeSwiplet(swiplet) }
    }

    func clearSwipletData(_ swiplet: String) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.clearSwipletData(swiplet) }
    }

    func exportSwiplet(_ swiplet: String, to file: URL) async throws {
        let box = UncheckedSendable(value: core)
        try await blocking { try box.value.exportSwiplet(swiplet, destination: file.path) }
    }


    private func handle(_ event: PlatformEvent) {
        switch event {
        case .dialog(let id, let request):
            handleDialog(id, request: request)
        case .service(let swiplet, let service):
            serviceChanged(swiplet, to: service)
        case .swipletsChanged:
            SwipletStore.shared.reload()
        case .apiFailed(let message):
            apiFailed(message)
        }
    }

    private func serviceChanged(_ swiplet: String, to service: SwipletService) {
        SwipletStore.shared.serviceChanged(swiplet, to: service)
        guard service.enabled, service.status == .failed else {
            if !service.enabled || service.status == .running {
                reportedServices.remove(swiplet)
            }
            return
        }
        guard reportedServices.insert(swiplet).inserted else { return }
        let title = SwipletStore.shared.titles[swiplet] ?? swiplet
        ErrorAlert.shared.report(AlertState(String(localized: "“\(title)” Stopped"), errorMessage: service.error))
    }

    private func handleDialog(_ dialogID: Int64, request: String?) {
        guard let request else {
            dialogs.removeValue(forKey: dialogID)?.cancel()
            return
        }
        let box = UncheckedSendable(value: core)
        guard #available(iOS 27, *), let decoded = try? JSONDecoder().decode(DialogRequest.self, from: Data(request.utf8)) else {
            box.value.dismissDialog(dialogID)
            return
        }
        dialogs[dialogID] = Task {
            do {
                let answer = try await ScriptDialogs.shared.present(decoded)
                box.value.answerDialog(dialogID, answer: answer.json)
            } catch {
                box.value.dismissDialog(dialogID)
            }
            dialogs.removeValue(forKey: dialogID)
        }
    }

    private func observeActivity() {
        let active = withPerceptionTracking {
            _ = (background.isEnabled, background.mode)
            return isActive
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeActivity() }
        }
        if active, !wasActive {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    Self.logger.error("Request notification authorization: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        wasActive = active
        let mode = active && background.isEnabled ? background.mode : nil
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
        device.setBrowsing(active)
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isActive && !location.isUpdating && !audio.isPlaying
    }

    private func apiFailed(_ message: String) {
        ErrorAlert.shared.report(AlertState(String(localized: "Couldn’t Publish the Swipt API"), errorMessage: message))
    }

    private var apiOptions: LibSwiptAPIOptions? {
        let cloudflare = developer.isCloudflareEnabled ? cloudflareTunnel : nil
        guard developer.isLocalNetworkEnabled || cloudflare != nil else { return nil }
        let options = LibSwiptAPIOptions()
        options.token = developer.token
        options.localNetwork = developer.isLocalNetworkEnabled
        options.port = Int32(developer.localPort)
        options.localNetworkAuthenticates = developer.localAuthenticates
        options.cloudflare = cloudflare
        options.cloudflarePath = developer.cloudflarePath
        return options
    }

    private func observeAPI() {
        let options = withPerceptionTracking {
            apiOptions
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeAPI() }
        }
        let advertisement = options.flatMap {
            $0.localNetwork ? APIAdvertisement(port: Int($0.port), authenticates: $0.localNetworkAuthenticates) : nil
        }
        let box = UncheckedSendable(value: (core, options))
        Self.queue.async { [weak self] in
            do {
                try box.value.0.setAPI(box.value.1)
                DispatchQueue.main.async { self?.advertiseAPI(advertisement) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.advertiseAPI(nil)
                    self?.apiFailed(message)
                }
            }
        }
    }

    private struct APIAdvertisement: Equatable {
        let port: Int
        let authenticates: Bool
    }

    private func advertiseAPI(_ advertisement: APIAdvertisement?) {
        guard advertisement != advertised else { return }
        advertised = advertisement
        guard let advertisement else {
            apiAdvertiser.stop()
            return
        }
        let error = apiAdvertiser.start(
            name: name, type: LibSwiptAPIServiceType, port: advertisement.port, txt: advertisement.authenticates ? ["auth": "1"] : [:])
        if error != kDNSServiceErr_NoError {
            advertisingFailed(error)
        }
    }

    private func advertisingFailed(_ errorCode: DNSServiceErrorType) {
        advertised = nil
        apiFailed(String(localized: "Bonjour advertising failed (error \(errorCode))."))
    }

    private func observeCloudflare() {
        let options = withPerceptionTracking { () -> LibSwiptCloudflareTunnelOptions? in
            guard developer.isCloudflareEnabled, developer.isCloudflareComplete else { return nil }
            let options = LibSwiptCloudflareTunnelOptions()
            options.mode = developer.cloudflareMode.rawValue
            if developer.cloudflareMode == .tunnel {
                options.account = developer.cloudflareAccount
                options.hostname = developer.cloudflareHostname
            }
            return options
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeCloudflare() }
        }
        cloudflareGeneration += 1
        cloudflareError = nil
        if let cloudflareTunnel {
            self.cloudflareTunnel = nil
            let box = UncheckedSendable(value: cloudflareTunnel)
            Self.queue.async {
                do { try box.value.close() } catch { Self.logger.error("Close the Cloudflare tunnel: \(error.localizedDescription, privacy: .public)") }
            }
        }
        guard let options else { return }
        let mode = developer.cloudflareMode
        options.tunnel = mode == .quickTunnel ? developer.cloudflareQuickTunnel : developer.cloudflareNamedTunnel
        let generation = cloudflareGeneration
        let events = CloudflareTunnelEvents { [weak self] tunnel, hostname in
            DispatchQueue.main.async { self?.handleCloudflareTunnel(mode, tunnel: tunnel, hostname: hostname, generation: generation) }
        } error: { [weak self] message in
            DispatchQueue.main.async { self?.handleCloudflareError(message, generation: generation) }
        }
        do {
            cloudflareTunnel = try core.newCloudflareTunnel(options, handler: events)
        } catch {
            apiFailed(error.localizedDescription)
        }
    }

    private func handleCloudflareError(_ message: String, generation: Int) {
        guard generation == cloudflareGeneration, message != cloudflareError else { return }
        cloudflareError = message
        apiFailed(message)
    }

    private func handleCloudflareTunnel(_ mode: CloudflareMode, tunnel: String, hostname: String, generation: Int) {
        guard generation == cloudflareGeneration else { return }
        switch mode {
        case .quickTunnel:
            developer.cloudflareQuickTunnel = tunnel
            developer.cloudflareQuickHostname = hostname
        case .tunnel:
            developer.cloudflareNamedTunnel = tunnel
        }
    }
}

nonisolated struct SwipletFileInfo: Sendable {
    let exists: Bool
    let name: String
    let directory: Bool
    let size: Int64
    let modified: Int64

    init(_ info: LibSwiptSwipletFileInfo) {
        exists = info.exists
        name = info.name
        directory = info.directory
        size = info.size
        modified = info.modified
    }
}
