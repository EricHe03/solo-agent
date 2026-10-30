import Foundation
import Perception

@Perceptible
final class AutoUnlockSettings {
    static let shared = AutoUnlockSettings()

    private enum Key {
        static let isEnabled = "serverAutoUnlocks"
        static let passcodeType = "serverAutoUnlockPasscodeType"
        static let passcode = "serverAutoUnlockPasscode"
    }

    var isEnabled: Bool {
        didSet { store.set(isEnabled, for: Key.isEnabled) }
    }

    var passcodeType: PasscodeType {
        didSet { store.set(passcodeType, for: Key.passcodeType) }
    }

    var passcode: String {
        didSet { store.set(passcode, for: Key.passcode) }
    }

    private let store = PreferenceStore.shared

    init() {
        isEnabled = store.value(Bool.self, for: Key.isEnabled) ?? false
        passcodeType = store.value(PasscodeType.self, for: Key.passcodeType) ?? .pin
        passcode = store.value(String.self, for: Key.passcode) ?? ""
    }

    var problem: String? {
        isEnabled ? passcodeType.problem(for: passcode) : nil
    }
}

enum PasscodeType: Int32, Codable {
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
