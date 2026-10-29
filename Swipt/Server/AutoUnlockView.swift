import Perception
import SwiftUI

struct AutoUnlockView: View {
    @FocusState private var isPasscodeFocused: Bool

    @Perception.Bindable private var settings = ServerSettings.shared

    var body: some View {
        WithPerceptionTracking {
            let problem = settings.autoUnlockPasscodeType.problem(for: settings.autoUnlockPasscode)
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.autoUnlocks)
                        .disabled(!settings.autoUnlocks && problem != nil)
                } footer: {
                    Text("Enable automatic unlock so scripts can unlock your device automatically when it’s locked.")
                }
                Section {
                    Picker("Passcode Type", selection: $settings.autoUnlockPasscodeType) {
                        Text("4-Digit or 6-Digit Code").tag(ServerPasscodeType.pin)
                        Text("Custom Numeric Code").tag(ServerPasscodeType.numeric)
                        Text("Custom Alphanumeric Code").tag(ServerPasscodeType.alphanumeric)
                    }
                    .pickerStyle(.menu)
                    LabeledContentCompat("Lock Screen Passcode") {
                        TextField("Lock Screen Passcode", text: $settings.autoUnlockPasscode.masked { isPasscodeFocused }, prompt: Text("Required"))
                            .textContentType(.oneTimeCode)
                            .keyboardType(settings.autoUnlockPasscodeType == .alphanumeric ? .asciiCapable : .asciiCapableNumberPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($isPasscodeFocused)
                            .submitLabel(.done)
                    }
                } header: {
                    Text("Passcode")
                } footer: {
                    if let problem {
                        Text(problem)
                            .foregroundStyle(settings.autoUnlockPasscode.isEmpty ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle("Automatic Unlock")
        }
    }
}
