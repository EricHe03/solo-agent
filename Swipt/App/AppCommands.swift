#if os(macOS)
import SwiftUI

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                HomeRequest.shared.pending = .settings
                openWindow(id: "home")
            }
            .keyboardShortcut(",")
        }

        CommandGroup(replacing: .help) {}
    }
}
#endif
