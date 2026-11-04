import Foundation
import Perception

@Perceptible
final class BackgroundSettings {
    static let shared = BackgroundSettings()

    private enum Key {
        static let isEnabled = "serverRunsInBackground"
        static let mode = "serverBackgroundMode"
    }

    var isEnabled: Bool {
        didSet { store.set(isEnabled, for: Key.isEnabled) }
    }

    var mode: BackgroundMode {
        didSet { store.set(mode, for: Key.mode) }
    }

    private let store = PreferenceStore.shared

    init() {
        isEnabled = store.value(Bool.self, for: Key.isEnabled) ?? true
        mode = store.value(BackgroundMode.self, for: Key.mode) ?? .audio
    }
}

enum BackgroundMode: String, Codable {
    case location
    case audio
}
