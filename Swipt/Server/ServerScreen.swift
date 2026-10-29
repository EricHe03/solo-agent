import Perception
import SwiftUI
import UIKit

struct ServerScreen: ViewModifier {
    @State private var isVisible = false

    private let controller = ServerController.shared

    func body(content: Content) -> some View {
        WithPerceptionTracking {
            content
                .alert(problemAlert)
                .onAppear {
                    isVisible = true
                    controller.remotePairing.start()
                    controller.startProbing()
                }
                .onDisappear {
                    isVisible = false
                    controller.remotePairing.stop()
                    controller.stopProbing()
                }
        }
    }

    private var problemAlert: Binding<AlertState?> {
        Binding {
            guard isVisible, case .failed(let problem) = controller.phase else { return nil }
            if problem.kind == .locationDenied {
                return AlertState(
                    title: problem.title,
                    actions: [
                        AlertState.Action(label: String(localized: "Open Settings"), role: nil) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        },
                        AlertState.Action(label: String(localized: "OK"), role: .cancel) {},
                    ])
            }
            return AlertState(problem.title, errorMessage: problem.message)
        } set: { state in
            guard state == nil, isVisible else { return }
            controller.dismissFailure()
        }
    }
}

struct ServerStatus: View {
    private let controller = ServerController.shared

    var body: some View {
        WithPerceptionTracking {
            if !controller.isActive, let problem = controller.startProblem {
                Text(problem)
            }
            if controller.tunnelThroughLocalNetwork {
                Text("Loopback through the local network performs poorly.")
                    .foregroundStyle(.yellow)
            }
            if !controller.isActive, controller.tunnelFound == false {
                Text("No loopback address found. Turn on [LocalDevVPN](https://apps.apple.com/app/id6755608044), or [sing-box](https://sing-box.sagernet.org) with `loopback_address` configured.")
                    .foregroundStyle(.red)
            }
        }
    }
}
