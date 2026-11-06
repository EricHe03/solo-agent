import Perception
import SwiftUI
import UIKit

struct AgentDeviceView: View {
    private let pairing = PairingStore.shared
    private let device = Platform.shared.device
    @State private var showsSetup = false
    @State private var isTesting = false

    var body: some View {
        WithPerceptionTracking {
            List {
                Section("Local Device") {
                    LabeledContent("Pairing") {
                        status(pairing.isPaired ? "Paired" : "Required", complete: pairing.isPaired)
                    }
                    LabeledContent("Developer connection") {
                        status(connectionText, complete: device.phase == .running)
                    }
                    LabeledContent("Loopback VPN") {
                        status(device.tunnelFound == true ? "Detected" : "Not detected", complete: device.tunnelFound == true)
                    }
                    if let name = pairing.device?.name {
                        LabeledContent("Device", value: name)
                    }
                }
                Section {
                    Button {
                        device.startProbing()
                        showsSetup = true
                    } label: {
                        Label("Review Device Setup", systemImage: "checklist")
                    }
                    Button {
                        testConnectivity()
                    } label: {
                        HStack {
                            Label("Test Connectivity", systemImage: "network")
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting)
                } footer: {
                    Text("Enable Developer Mode in iOS Settings › Privacy & Security. Pair this iPhone with itself, then keep one compatible loopback packet-tunnel VPN active. Only one iOS packet-tunnel VPN can normally be active at a time.")
                }
                Section {
                    NavigationLink {
                        BackgroundView()
                    } label: {
                        Label("Background Service", systemImage: "arrow.clockwise.circle")
                    }
                    NavigationLink {
                        AutoUnlockView()
                    } label: {
                        Label("Automatic Unlock", systemImage: "lock.open")
                    }
                } header: {
                    Text("Background Operation")
                } footer: {
                    Text("Solo Agent reuses Swipt’s audio/location keep-active mechanisms while a task runs. iOS can still suspend or terminate the app; uninterrupted background execution is not guaranteed.")
                }
            }
            .navigationTitle("Device Setup")
            .sheet(isPresented: $showsSetup, onDismiss: { device.stopProbing() }) {
                SetupView()
            }
        }
    }

    private func testConnectivity() {
        isTesting = true
        device.startProbing()
        Task {
            try? await Task.sleep(seconds: 5)
            device.stopProbing()
            isTesting = false
        }
    }

    private var connectionText: String {
        switch device.phase {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .preparing: "Preparing services"
        case .running: "Connected"
        case .failed: "Failed — review setup"
        }
    }

    private func status(_ text: String, complete: Bool) -> some View {
        Label(text, systemImage: complete ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(complete ? Color.green : Color.orange)
    }
}
