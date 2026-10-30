import Perception
import SwiftUI

struct BackgroundView: View {
    @Perception.Bindable private var settings = BackgroundSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.isEnabled)
                    if settings.isEnabled {
                        Picker("Keep Running With", selection: $settings.mode) {
                            Text("Location Service").tag(BackgroundMode.location)
                            Text("Audio Service").tag(BackgroundMode.audio)
                        }
                        .pickerStyle(.menu)
                    }
                } footer: {
                    Text("Swipt needs to stay running in the background to keep automating this device.")
                }
            }
            .navigationTitle("Background Service")
        }
    }
}
