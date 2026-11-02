import Perception
import SwiftUI
import UIKit

enum SetupStep {
    case loopback
    case autoUnlock
}

struct SetupView: View {
    static var isNeeded: Bool {
        !PairingStore.shared.isPaired || Platform.shared.device.tunnelFound == false || !AutoUnlockSettings.shared.isDecided
    }

    @State private var path: [SetupStep] = []

    private let pairing = PairingStore.shared
    private let device = Platform.shared.device

    var body: some View {
        WithPerceptionTracking {
            NavigationStack(path: $path) {
                PairingSetupView { path.append(.loopback) }
                    .navigationDestination(for: SetupStep.self) { step in
                        switch step {
                        case .loopback:
                            LoopbackSetupView { path.append(.autoUnlock) }
                        case .autoUnlock:
                            AutoUnlockSetupView {}
                        }
                    }
            }
            .onAppear {
                if pairing.isPaired {
                    path = device.tunnelFound == false ? [.loopback] : [.autoUnlock]
                }
            }
            .onChangeCompat(of: pairing.isPaired) { paired in
                if !paired {
                    path = []
                }
            }
        }
    }
}

struct LoopbackSetupView: View {
    let next: () -> Void

    private static let localDevVPN = URL(string: "localdevvpn://")!
    private static let localDevVPNStore = URL(string: "https://apps.apple.com/app/id6755608044")!
    private static let singBox = URL(string: "sing-box://")!
    private static let singBoxStore = URL(string: "https://apps.apple.com/app/id6785326793")!
    private static let profile = Bundle.main.url(forResource: "LocalDevVPN", withExtension: "bpf")!

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasLocalDevVPN = false
    @State private var hasSingBox = false

    private let device = Platform.shared.device

    var body: some View {
        SetupPage("network", Text("Loopback VPN"), description: Text("Swipt needs a loopback VPN to connect to developer services. LocalDevVPN or sing-box is recommended.")) {
            VStack(spacing: 24) {
                Divider()
                VStack(spacing: 12) {
                    if hasLocalDevVPN {
                        SetupPrimaryButton(title: Text("Open LocalDevVPN")) { UIApplication.shared.open(Self.localDevVPN) }
                    } else {
                        SetupPrimaryButton(title: Text("Get LocalDevVPN")) { UIApplication.shared.open(Self.localDevVPNStore) }
                    }
                }
                Divider()
                VStack(spacing: 12) {
                    if hasSingBox {
                        SetupPrimaryButton(title: Text("Open sing-box")) { UIApplication.shared.open(Self.singBox) }
                        SetupSecondaryButton(title: Text("Import example profile into sing-box"), action: shareProfile)
                    } else {
                        SetupPrimaryButton(title: Text("Get sing-box")) { UIApplication.shared.open(Self.singBoxStore) }
                    }
                }
            }
            .frame(maxWidth: 480)
            .padding(.top, 8)
        } actions: {
        }
        .onChangeCompat(of: scenePhase == .active, initial: true) { active in
            guard active else { return }
            hasLocalDevVPN = UIApplication.shared.canOpenURL(Self.localDevVPN)
            hasSingBox = UIApplication.shared.canOpenURL(Self.singBox)
        }
        .onChangeCompat(of: device.tunnelFound == true) { found in
            if found {
                next()
            }
        }
    }

    private func shareProfile() {
        guard let top = topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [Self.profile], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(origin: CGPoint(x: top.view.bounds.midX, y: top.view.bounds.midY), size: .zero)
            popover.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }
}
