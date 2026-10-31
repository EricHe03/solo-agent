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
