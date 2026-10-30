import Perception
import SwiftUI

struct AutoUnlockView: View {
    @FocusState private var isPasscodeFocused: Bool

    @Perception.Bindable private var settings = AutoUnlockSettings.shared

    var body: some View {
        WithPerceptionTracking {
            let problem = settings.passcodeType.problem(for: settings.passcode)
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.isEnabled)
                        .disabled(!settings.isEnabled && problem != nil)
                } footer: {
                    Text("Enable automatic unlock so scripts can unlock your device automatically when it’s locked.")
                }
                Section {
                    Picker("Passcode Type", selection: $settings.passcodeType) {
                        Text("4-Digit or 6-Digit Code").tag(PasscodeType.pin)
                        Text("Custom Numeric Code").tag(PasscodeType.numeric)
                        Text("Custom Alphanumeric Code").tag(PasscodeType.alphanumeric)
                    }
                    .pickerStyle(.menu)
                    LabeledContentCompat("Lock Screen Passcode") {
                        TextField("Lock Screen Passcode", text: $settings.passcode.masked { isPasscodeFocused }, prompt: Text("Required"))
                            .textContentType(.oneTimeCode)
                            .keyboardType(settings.passcodeType == .alphanumeric ? .asciiCapable : .asciiCapableNumberPad)
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
                            .foregroundStyle(settings.passcode.isEmpty ? Color.secondary : Color.red)
                    }
                }
            }
            .navigationTitle("Automatic Unlock")
        }
    }
}
