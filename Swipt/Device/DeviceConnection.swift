import Foundation
import LibSwipt
import Perception
import os

@Perceptible
final class DeviceConnection {
    nonisolated private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "device")

    enum Phase: Equatable {
        case idle
        case connecting
        case preparing
        case running
        case failed

        var isConnected: Bool {
            switch self {
            case .idle, .failed: false
            case .connecting, .preparing, .running: true
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var problem: DeviceProblem?
    private(set) var tunnelFound: Bool?
    private(set) var tunnelThroughLocalNetwork = false

    let remotePairing = RemotePairingBrowser()
    let pairingSession: PairingSession
    @PerceptionIgnored private let device: LibSwiptDevice
    @PerceptionIgnored private var probeTask: Task<Void, Never>?
    @PerceptionIgnored private var probeClients = 0
    @PerceptionIgnored private var isBrowsing = false

    private var autoUnlock: AutoUnlockSettings { .shared }
    private var pairing: PairingStore { .shared }

    init(_ device: LibSwiptDevice, events: DeviceEvents) {
        self.device = device
        pairingSession = PairingSession(device: device)
        remotePairing.onPortChange = { [weak self] port in
            self?.device.setRemotePairingPort(Int32(port))
        }
        events.connect { [weak self] change in
            DispatchQueue.main.async { self?.handle(change) }
        }
    }

    var unavailableReason: String? {
        if !pairing.isPaired {
            return String(localized: "Pair and import the Developer Disk Image in Settings › Device first.")
        }
        if autoUnlock.problem != nil {
            return String(localized: "Check Settings › Automatic Unlock.")
        }
        if DiskImageStore.shared.isImporting {
            return String(localized: "The Developer Disk Image is still importing.")
        }
        return nil
    }

    func start() {
        observePairing()
        observeAvailability()
        observeSettings()
    }

    func clearFailure() {
        problem = nil
        if phase == .failed {
            phase = .idle
        }
    }

    func setBrowsing(_ browsing: Bool) {
        guard browsing != isBrowsing else { return }
        isBrowsing = browsing
        if browsing {
            remotePairing.start()
        } else {
            remotePairing.stop()
        }
    }

    func startProbing() {
        remotePairing.start()
        probeClients += 1
        guard probeTask == nil else { return }
        probeTask = Task {
            while !Task.isCancelled {
                let found: Bool
                let throughLocalNetwork: Bool
                if phase == .preparing || phase == .running {
                    found = true
                    throughLocalNetwork = device.loopbackAddress()?.localNetwork ?? false
                } else {
                    let port = remotePairing.port ?? 0
                    let probe = UncheckedSendable(value: LibSwiptNewLoopbackProbe(Int32(port))!)
                    let result = await withTaskCancellationHandler {
                        do {
                            let localNetwork = try await blocking { try probe.value.run().localNetwork }
                            return (found: true, localNetwork: localNetwork)
                        } catch {
                            return (found: false, localNetwork: false)
                        }
                    } onCancel: {
                        probe.value.cancel()
                    }
                    guard !Task.isCancelled else { return }
                    found = result.found
                    throughLocalNetwork = result.localNetwork
                }
                if tunnelFound != found {
                    tunnelFound = found
                }
                if tunnelThroughLocalNetwork != throughLocalNetwork {
                    tunnelThroughLocalNetwork = throughLocalNetwork
                }
                try? await Task.sleep(seconds: 2)
            }
        }
    }

    func stopProbing() {
        remotePairing.stop()
        probeClients = max(0, probeClients - 1)
        guard probeClients == 0 else { return }
        probeTask?.cancel()
        probeTask = nil
    }

    private func observePairing() {
        let record = withPerceptionTracking {
            pairing.record
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observePairing() }
        }
        configure { try $0.setPairingRecord(record ?? Data()) }
    }

    private func observeAvailability() {
        let message = withPerceptionTracking {
            unavailableReason ?? ""
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeAvailability() }
        }
        configure { $0.setUnavailable(message) }
    }

    private var settings: LibSwiptDeviceSettings {
        let settings = LibSwiptDeviceSettings()
        settings.autoUnlockPasscode = autoUnlock.isEnabled && autoUnlock.problem == nil ? autoUnlock.passcode : ""
        settings.autoUnlockPasscodeType = autoUnlock.passcodeType.rawValue
        return settings
    }

    private func observeSettings() {
        let settings = withPerceptionTracking {
            self.settings
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeSettings() }
        }
        let box = UncheckedSendable(value: settings)
        configure { try $0.update(box.value) }
    }

    private func configure(_ change: @escaping @Sendable (LibSwiptDevice) throws -> Void) {
        let box = UncheckedSendable(value: device)
        Platform.queue.async { [weak self] in
            do {
                try change(box.value)
            } catch {
                Self.logger.error("Configure the device: \(error.localizedDescription, privacy: .public)")
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.problem = DeviceProblem(kind: .other, message: message)
                }
            }
        }
    }

    private func handle(_ change: DeviceStateChange) {
        let problem = change.errorCode == LibSwiptDeviceErrorNone ? nil : DeviceProblem(code: change.errorCode, message: change.message)
        switch change.state {
        case LibSwiptDeviceConnecting:
            phase = .connecting
        case LibSwiptDevicePreparing:
            phase = .preparing
        case LibSwiptDeviceConnected:
            phase = .running
        case LibSwiptDeviceFailed:
            phase = .failed
        default:
            phase = problem == nil ? .idle : .failed
        }
        self.problem = phase == .failed ? problem ?? DeviceProblem(kind: .other, message: change.message) : problem
    }
}
