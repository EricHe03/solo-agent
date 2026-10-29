import Perception
import SwiftUI

struct ServicesView: View {
    @State private var isShowingPairing = false
    @State private var isShowingDiskImage = false
    @FocusState private var isPasscodeFocused: Bool

    private let controller = ServerController.shared
    @Perception.Bindable private var settings = ServerSettings.shared
    private let pairing = PairingStore.shared
    private let diskImage = DiskImageStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                if pairing.isPaired {
                    autoUnlockSection
                    backgroundSection
                }
                setupSection
            }
            .navigationTitle("Services")
            .sheet(isPresented: $isShowingPairing) {
                PairingSetupView()
            }
            .sheet(isPresented: $isShowingDiskImage) {
                DiskImageImportView()
            }
            .onChangeCompat(of: pairing.revision) {
                controller.remotePairing.refresh()
                if case .failed = controller.phase {
                    controller.stop()
                }
            }
        }
    }

    private var autoUnlockSection: some View {
        Section {
            Toggle("Enabled", isOn: $settings.autoUnlocks)
            if settings.autoUnlocks {
                Picker("Passcode Type", selection: $settings.autoUnlockPasscodeType) {
                    Text("4-Digit or 6-Digit Code").tag(ServerPasscodeType.pin)
                    Text("Custom Numeric Code").tag(ServerPasscodeType.numeric)
                    Text("Custom Alphanumeric Code").tag(ServerPasscodeType.alphanumeric)
                }
                .pickerStyle(.menu)
                LabeledContentCompat("Device Passcode") {
                    TextField("Device Passcode", text: $settings.autoUnlockPasscode.masked { isPasscodeFocused }, prompt: Text("Required"))
                        .textContentType(.oneTimeCode)
                        .keyboardType(settings.autoUnlockPasscodeType == .alphanumeric ? .asciiCapable : .asciiCapableNumberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.trailing)
                        .focused($isPasscodeFocused)
                        .submitLabel(.done)
                }
            }
        } header: {
            Text("Automatic Unlock")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Swipt needs your passcode to automatically unlock the device when connected.")
                if let problem = settings.autoUnlockProblem {
                    Text(problem)
                        .foregroundStyle(.red)
                }
            }
        }
        .disabled(controller.isActive)
    }

    private var backgroundSection: some View {
        Section {
            Toggle("Enabled", isOn: $settings.runsInBackground)
            if settings.runsInBackground {
                Picker("Keep Running With", selection: $settings.backgroundMode) {
                    Text("Location Service").tag(ServerBackgroundMode.location)
                    Text("Audio Service").tag(ServerBackgroundMode.audio)
                }
                .pickerStyle(.menu)
            }
        } header: {
            Text("Background Service")
        } footer: {
            Text("Swipt needs to stay running in the background to keep automating this device.")
        }
        .onChangeCompat(of: settings.runsInBackground) { controller.updateBackground() }
        .onChangeCompat(of: settings.backgroundMode) { controller.updateBackground() }
    }

    private var setupSection: some View {
        Section {
            Button(pairing.isPaired ? "Pair Again" : "Pair") { isShowingPairing = true }
            Button(diskImage.isImported ? "Import Disk Image Again" : "Import Disk Image") { isShowingDiskImage = true }
        } header: {
            Text("Setup")
        } footer: {
            Text("Swipt needs to pair with developer services and import the Developer Disk Image to automate this device.")
        }
        .disabled(controller.isActive)
    }
}
