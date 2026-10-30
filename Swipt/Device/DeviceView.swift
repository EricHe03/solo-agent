import Perception
import SwiftUI
import UIKit

struct DeviceView: View {
    static var systemImage: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @State private var isShowingPairing = false
    @State private var isShowingDiskImage = false

    private let device = Platform.shared.device
    private let pairing = PairingStore.shared
    private let diskImage = DiskImageStore.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                connectionSection
                setupSection
            }
            .navigationTitle("Device")
            .sheet(isPresented: $isShowingPairing) {
                PairingSetupView()
            }
            .sheet(isPresented: $isShowingDiskImage) {
                DiskImageImportView()
            }
            .onChangeCompat(of: pairing.revision) {
                device.remotePairing.refresh()
                device.clearFailure()
            }
        }
    }

    private var status: String {
        switch device.phase {
        case .idle: String(localized: "Not Connected")
        case .connecting: device.problem?.title ?? String(localized: "Connecting…")
        case .preparing: String(localized: "Preparing…")
        case .running: device.problem?.title ?? String(localized: "Connected")
        case .failed: device.problem?.title ?? DeviceProblem(kind: .other, message: "").title
        }
    }

    private var connectionSection: some View {
        Section {
            LabeledContentCompat("Status") {
                Text(verbatim: status)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let message = device.problem?.message, !message.isEmpty {
                    Text(verbatim: message)
                }
                if let reason = device.unavailableReason {
                    Text(reason)
                }
            }
        }
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
        .disabled(device.phase.isConnected)
    }
}
