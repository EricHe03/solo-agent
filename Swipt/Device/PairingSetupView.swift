import Perception
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PairingSetupView: View {
    var next: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isPickingFile = false
    @State private var alert: AlertState?

    private let pairing = PairingStore.shared
    private let session = Platform.shared.device.pairingSession

    var body: some View {
        WithPerceptionTracking {
            SetupPage(
                "link", Text("Pair with This Device"),
                description: Text("Swipt needs to pair with this device to connect to its developer services.")
            ) {
                PairingGuideView(hostName: session.hostName)
                VStack(alignment: .leading, spacing: 12) {
                    SetupStepLine(number: 1, text: Text("Go to Settings › Privacy & Security › Developer Mode."))
                    SetupStepLine(number: 2, text: Text("Tap “\("Pair with \(session.hostName)")”."))
                    SetupStepLine(number: 3, text: Text("Enter the pairing code shown here."))
                }
                switch session.state {
                case .code(let pin):
                    PairingCodeView(pin: pin)
                case .waiting:
                    InlineProgress("Waiting for Settings")
                case .idle, .failed:
                    EmptyView()
                }
            } actions: {
                SetupPrimaryButton(title: Text("Pair in Settings"), action: pairInSettings)
                if session.isInProgress {
                    SetupSecondaryButton(title: Text("Cancel")) { session.cancel() }
                } else {
                    SetupSecondaryButton(title: Text("Import Pairing File…")) { isPickingFile = true }
                }
            }
            .navigationBarBackButtonHidden(session.isInProgress)
            .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    importFile(url)
                }
            }
            .alert(problemAlert)
            .onChangeCompat(of: pairing.revision) {
                guard pairing.isPaired else { return }
                if let next {
                    next()
                } else {
                    dismiss()
                }
            }
        }
    }

    private var problemAlert: Binding<AlertState?> {
        Binding {
            if let alert {
                return alert
            }
            if case .failed(let problem) = session.state {
                return AlertState(problem.title, errorMessage: problem.message)
            }
            return nil
        } set: { state in
            guard state == nil else { return }
            alert = nil
            session.acknowledgeFailure()
        }
    }

    private func pairInSettings() {
        session.start()
        guard session.isInProgress else { return }
        Task {
            if let url = URL(string: "App-Prefs:"), await UIApplication.shared.open(url) { return }
            if let url = URL(string: UIApplication.openSettingsURLString) {
                _ = await UIApplication.shared.open(url)
            }
        }
    }

    private func importFile(_ url: URL) {
        Task {
            do {
                try pairing.save(try await url.pickedFileContents())
            } catch {
                alert = AlertState(String(localized: "Couldn’t Import the Pairing File"), error: error)
            }
        }
    }
}

private struct PairingCodeView: View {
    let pin: String

    var body: some View {
        Text(verbatim: PairingSession.grouped(pin))
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .textSelection(.enabled)
            .accessibilityLabel(Text(verbatim: pin.map(String.init).joined(separator: " ")))
            .padding(.vertical, 8)
    }
}
