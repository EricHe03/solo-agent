import Foundation
import Perception

@Perceptible
final class DeveloperSettings {
    static let shared = DeveloperSettings()

    static let portRange = 1...65535

    private enum Key {
        static let token = "developerToken"
        static let localNetworkEnabled = "developerLocalNetworkEnabled"
        static let localPort = "developerLocalPort"
        static let localAuthenticates = "developerLocalAuthenticates"
        static let cloudflareEnabled = "developerCloudflareEnabled"
        static let cloudflarePath = "developerCloudflarePath"
        static let cloudflareMode = "developerCloudflareMode"
        static let cloudflareAccount = "developerCloudflareAccount"
        static let cloudflareZone = "developerCloudflareZone"
        static let cloudflareHostname = "developerCloudflareHostname"
        static let cloudflareQuickTunnel = "developerCloudflareQuickTunnel"
        static let cloudflareQuickHostname = "developerCloudflareQuickHostname"
        static let cloudflareNamedTunnel = "developerCloudflareNamedTunnel"
    }

    var token: String {
        didSet { store.set(token, for: Key.token) }
    }

    var isLocalNetworkEnabled: Bool {
        didSet { store.set(isLocalNetworkEnabled, for: Key.localNetworkEnabled) }
    }

    var localPort: Int {
        didSet { store.set(localPort, for: Key.localPort) }
    }

    var localAuthenticates: Bool {
        didSet { store.set(localAuthenticates, for: Key.localAuthenticates) }
    }

    var isCloudflareEnabled: Bool {
        didSet { store.set(isCloudflareEnabled, for: Key.cloudflareEnabled) }
    }

    var cloudflarePath: String {
        didSet { store.set(cloudflarePath, for: Key.cloudflarePath) }
    }

    var cloudflareMode: CloudflareMode {
        didSet { store.set(cloudflareMode, for: Key.cloudflareMode) }
    }

    var cloudflareAccount: String {
        didSet { store.set(cloudflareAccount, for: Key.cloudflareAccount) }
    }

    var cloudflareZone: String {
        didSet { store.set(cloudflareZone, for: Key.cloudflareZone) }
    }

    var cloudflareHostname: String {
        didSet { store.set(cloudflareHostname, for: Key.cloudflareHostname) }
    }

    var cloudflareQuickTunnel: String {
        didSet { store.set(cloudflareQuickTunnel, for: Key.cloudflareQuickTunnel) }
    }

    var cloudflareQuickHostname: String {
        didSet { store.set(cloudflareQuickHostname, for: Key.cloudflareQuickHostname) }
    }

    var cloudflareNamedTunnel: String {
        didSet { store.set(cloudflareNamedTunnel, for: Key.cloudflareNamedTunnel) }
    }

    private let store = PreferenceStore.shared

    init() {
        let storedToken = store.value(String.self, for: Key.token)
        token = storedToken ?? Self.randomHex(32)
        isLocalNetworkEnabled = store.value(Bool.self, for: Key.localNetworkEnabled) ?? false
        let storedPort = store.value(Int.self, for: Key.localPort)
        localPort = storedPort ?? Int.random(in: 10000...49151)
        localAuthenticates = store.value(Bool.self, for: Key.localAuthenticates) ?? true
        isCloudflareEnabled = store.value(Bool.self, for: Key.cloudflareEnabled) ?? false
        cloudflarePath = store.value(String.self, for: Key.cloudflarePath) ?? "/"
        cloudflareMode = store.value(CloudflareMode.self, for: Key.cloudflareMode) ?? .quickTunnel
        cloudflareAccount = store.value(String.self, for: Key.cloudflareAccount) ?? ""
        cloudflareZone = store.value(String.self, for: Key.cloudflareZone) ?? ""
        cloudflareHostname = store.value(String.self, for: Key.cloudflareHostname) ?? ""
        cloudflareQuickTunnel = store.value(String.self, for: Key.cloudflareQuickTunnel) ?? ""
        cloudflareQuickHostname = store.value(String.self, for: Key.cloudflareQuickHostname) ?? ""
        cloudflareNamedTunnel = store.value(String.self, for: Key.cloudflareNamedTunnel) ?? ""
        if storedToken == nil {
            store.set(token, for: Key.token)
        }
        if storedPort == nil {
            store.set(localPort, for: Key.localPort)
        }
    }

    static func randomHex(_ length: Int) -> String {
        String((0..<length).map { _ in "0123456789abcdef".randomElement()! })
    }

    var isPublishing: Bool {
        isLocalNetworkEnabled || isCloudflareEnabled
    }

    var isCloudflareComplete: Bool {
        cloudflareMode == .quickTunnel || (!cloudflareAccount.isEmpty && !cloudflareHostname.isEmpty)
    }

    var cloudflarePathPrefix: String {
        cloudflarePath == "/" ? "" : cloudflarePath
    }

    var cloudflarePublicHostname: String {
        switch cloudflareMode {
        case .quickTunnel: isCloudflareEnabled ? cloudflareQuickHostname : ""
        case .tunnel: cloudflareHostname
        }
    }
}

enum CloudflareMode: Int32, Codable {
    case quickTunnel = 0
    case tunnel = 1

    var name: String {
        switch self {
        case .quickTunnel: "Quick Tunnel"
        case .tunnel: "Tunnel"
        }
    }
}
