import Foundation
import Perception

@Perceptible
final class ServerSettings {
    static let shared = ServerSettings()

    static let mcpPortRange = 1...65535
    static let defaultMCPPort = 5910

    private enum Key {
        static let runsInBackground = "serverRunsInBackground"
        static let backgroundMode = "serverBackgroundMode"
        static let autoUnlocks = "serverAutoUnlocks"
        static let autoUnlockPasscodeType = "serverAutoUnlockPasscodeType"
        static let autoUnlockPasscode = "serverAutoUnlockPasscode"
        static let mcpPort = "serverMCPPort"
        static let mcpAuthenticates = "serverMCPAuthenticates"
        static let mcpToken = "serverMCPToken"
        static let localMCPEnabled = "serverMCPLocalEnabled"
        static let cloudflareEnabled = "serverCloudflareEnabled"
        static let cloudflareMode = "serverCloudflareMode"
        static let cloudflarePath = "serverCloudflarePath"
        static let cloudflareToken = "serverCloudflareToken"
        static let cloudflareAccount = "serverCloudflareAccount"
        static let cloudflareZone = "serverCloudflareZone"
        static let cloudflareHostname = "serverCloudflareHostname"
        static let cloudflareQuickTunnel = "serverCloudflareQuickTunnel"
        static let cloudflareQuickHostname = "serverCloudflareQuickHostname"
        static let cloudflareNamedTunnel = "serverCloudflareNamedTunnel"
    }

    var runsInBackground: Bool {
        didSet { store.set(runsInBackground, for: Key.runsInBackground) }
    }

    var backgroundMode: ServerBackgroundMode {
        didSet { store.set(backgroundMode, for: Key.backgroundMode) }
    }

    var autoUnlocks: Bool {
        didSet { store.set(autoUnlocks, for: Key.autoUnlocks) }
    }

    var autoUnlockPasscodeType: ServerPasscodeType {
        didSet { store.set(autoUnlockPasscodeType, for: Key.autoUnlockPasscodeType) }
    }

    var autoUnlockPasscode: String {
        didSet { store.set(autoUnlockPasscode, for: Key.autoUnlockPasscode) }
    }

    var mcpPort: Int {
        didSet { store.set(mcpPort, for: Key.mcpPort) }
    }

    var mcpAuthenticates: Bool {
        didSet { store.set(mcpAuthenticates, for: Key.mcpAuthenticates) }
    }

    var mcpToken: String {
        didSet { store.set(mcpToken, for: Key.mcpToken) }
    }

    var isLocalMCPEnabled: Bool {
        didSet { store.set(isLocalMCPEnabled, for: Key.localMCPEnabled) }
    }

    var isCloudflareEnabled: Bool {
        didSet { store.set(isCloudflareEnabled, for: Key.cloudflareEnabled) }
    }

    var cloudflareMode: CloudflareMode {
        didSet { store.set(cloudflareMode, for: Key.cloudflareMode) }
    }

    var cloudflarePath: String {
        didSet { store.set(cloudflarePath, for: Key.cloudflarePath) }
    }

    var cloudflareToken: String {
        didSet { store.set(cloudflareToken, for: Key.cloudflareToken) }
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
        runsInBackground = store.value(Bool.self, for: Key.runsInBackground) ?? true
        backgroundMode = store.value(ServerBackgroundMode.self, for: Key.backgroundMode) ?? .location
        autoUnlocks = store.value(Bool.self, for: Key.autoUnlocks) ?? false
        autoUnlockPasscodeType = store.value(ServerPasscodeType.self, for: Key.autoUnlockPasscodeType) ?? .pin
        autoUnlockPasscode = store.value(String.self, for: Key.autoUnlockPasscode) ?? ""
        mcpPort = store.value(Int.self, for: Key.mcpPort) ?? Self.defaultMCPPort
        mcpAuthenticates = store.value(Bool.self, for: Key.mcpAuthenticates) ?? false
        mcpToken = store.value(String.self, for: Key.mcpToken) ?? ""
        isLocalMCPEnabled = store.value(Bool.self, for: Key.localMCPEnabled) ?? false
        isCloudflareEnabled = store.value(Bool.self, for: Key.cloudflareEnabled) ?? false
        cloudflareMode = store.value(CloudflareMode.self, for: Key.cloudflareMode) ?? .quickTunnel
        cloudflarePath = store.value(String.self, for: Key.cloudflarePath) ?? "/mcp"
        let storedCloudflareToken = store.value(String.self, for: Key.cloudflareToken)
        cloudflareToken = storedCloudflareToken ?? Self.randomHex(32)
        cloudflareAccount = store.value(String.self, for: Key.cloudflareAccount) ?? ""
        cloudflareZone = store.value(String.self, for: Key.cloudflareZone) ?? ""
        cloudflareHostname = store.value(String.self, for: Key.cloudflareHostname) ?? ""
        cloudflareQuickTunnel = store.value(String.self, for: Key.cloudflareQuickTunnel) ?? ""
        cloudflareQuickHostname = store.value(String.self, for: Key.cloudflareQuickHostname) ?? ""
        cloudflareNamedTunnel = store.value(String.self, for: Key.cloudflareNamedTunnel) ?? ""
        if storedCloudflareToken == nil {
            store.set(cloudflareToken, for: Key.cloudflareToken)
        }
    }

    static func randomHex(_ length: Int) -> String {
        String((0..<length).map { _ in "0123456789abcdef".randomElement()! })
    }

    var isMCPEnabled: Bool {
        isLocalMCPEnabled || isCloudflareEnabled
    }

    var isLocalMCPComplete: Bool {
        !mcpAuthenticates || !mcpToken.isEmpty
    }

    var isCloudflareComplete: Bool {
        !cloudflareToken.isEmpty && (cloudflareMode == .quickTunnel || (!cloudflareAccount.isEmpty && !cloudflareHostname.isEmpty))
    }

    var isMCPComplete: Bool {
        (!isLocalMCPEnabled || isLocalMCPComplete) && (!isCloudflareEnabled || isCloudflareComplete)
    }

    var autoUnlockProblem: String? {
        autoUnlocks ? autoUnlockPasscodeType.problem(for: autoUnlockPasscode) : nil
    }
}

enum ServerPasscodeType: Int32, Codable {
    case pin = 0
    case numeric = 1
    case alphanumeric = 2

    func problem(for passcode: String) -> String? {
        guard !passcode.isEmpty else { return String(localized: "Enter this device’s lock screen passcode.") }
        guard passcode.utf8.count <= 64 else { return String(localized: "Automatic unlock supports passcodes up to 64 characters.") }
        let isNumeric = passcode.utf8.allSatisfy { (0x30...0x39).contains($0) }
        switch self {
        case .pin:
            guard isNumeric && (passcode.utf8.count == 4 || passcode.utf8.count == 6) else {
                return String(localized: "Enter a 4-digit or 6-digit passcode, or select the passcode type used by this device.")
            }
        case .numeric:
            guard isNumeric else { return String(localized: "A custom numeric passcode can contain only digits from 0 to 9.") }
        case .alphanumeric:
            guard passcode.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else {
                return String(localized: "Automatic unlock supports English letters, numbers, spaces, and standard punctuation. Other characters aren’t supported.")
            }
        }
        return nil
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

enum ServerBackgroundMode: String, Codable {
    case location
    case audio
}
