import Perception
import SwiftUI

@Perceptible
final class HomeRequest {
    enum Pending: Equatable {
        case settings
    }

    static let shared = HomeRequest()
    var pending: Pending?
}

enum HomeTab: Hashable {
    case automation
    case developer
    case settings
}

struct HomeView: View {
    @State private var selection: HomeTab = .automation
    private let homeRequest = HomeRequest.shared
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @State private var isProbing = false
    private let developer = DeveloperSettings.shared
    #endif

    var body: some View {
        layout
            .modifier(ErrorAlertPresenter())
            .onChangeCompat(of: homeRequest.pending, initial: true) { pending in
                guard let pending else { return }
                homeRequest.pending = nil
                switch pending {
                case .settings: selection = .settings
                }
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        WithPerceptionTracking {
            if Platform.isSupported, Platform.shared.device.tunnelFound == false {
                LoopbackRequiredView()
            } else if #available(iOS 18, *) {
                TabView(selection: $selection) {
                    Tab("Automation", systemImage: "wand.and.stars", value: HomeTab.automation) {
                        NavigationStackCompat {
                            automationView
                        }
                    }
                    Tab("Developer", systemImage: "terminal", value: HomeTab.developer) {
                        NavigationStackCompat {
                            developerView
                        }
                    }
                    .badge(isPublishing ? Text(verbatim: "") : nil)
                    .accessibilityValue(Text("Published"), isEnabled: isPublishing)
                    Tab("Settings", systemImage: "gearshape", value: HomeTab.settings) {
                        NavigationStackCompat {
                            SettingsView()
                        }
                    }
                }
                .tabViewStyle(.sidebarAdaptable)
            } else {
                TabView(selection: $selection) {
                    NavigationStackCompat {
                        automationView
                    }
                    .tabItem { Label("Automation", systemImage: "wand.and.stars") }
                    .tag(HomeTab.automation)
                    NavigationStackCompat {
                        developerView
                    }
                    .tabItem { Label("Developer", systemImage: "terminal") }
                    .tag(HomeTab.developer)
                    .badge(isPublishing ? Text(verbatim: "") : nil)
                    .accessibilityValue(isPublishing ? Text("Published") : Text(verbatim: ""))
                    NavigationStackCompat {
                        SettingsView()
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(HomeTab.settings)
                }
            }
        }
        .onChangeCompat(of: scenePhase == .active, initial: true) { active in
            guard Platform.isSupported, active != isProbing else { return }
            isProbing = active
            if active {
                Platform.shared.device.startProbing()
            } else {
                Platform.shared.device.stopProbing()
            }
        }
        #else
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { if let page = $0 { selection = page } })) {
                Label("Automation", systemImage: "wand.and.stars")
                    .tag(HomeTab.automation)
                Label("Developer", systemImage: "terminal")
                    .tag(HomeTab.developer)
                Label("Settings", systemImage: "gearshape")
                    .tag(HomeTab.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
        } detail: {
            NavigationStack {
                switch selection {
                case .automation:
                    ContentUnavailableView("Not Available on Mac", systemImage: "desktopcomputer")
                        .navigationTitle("Automation")
                case .developer:
                    ContentUnavailableView("Not Available on Mac", systemImage: "desktopcomputer")
                        .navigationTitle("Developer")
                case .settings:
                    SettingsView()
                }
            }
            .id(selection)
        }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var automationView: some View {
        if #available(iOS 27, *), Platform.isSupported {
            AutomationView()
        } else {
            PlatformUnsupportedView(title: "Automation")
        }
    }

    @ViewBuilder
    private var developerView: some View {
        if Platform.isSupported {
            DeveloperView()
        } else {
            PlatformUnsupportedView(title: "Developer")
        }
    }

    private var isPublishing: Bool {
        Platform.isSupported && developer.isPublishing
    }
    #endif
}
