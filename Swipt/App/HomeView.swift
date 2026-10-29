import Perception
import SwiftUI

@Perceptible
final class HomeRequest {
    enum Pending: Equatable {
        case settings
        case mcp
    }

    static let shared = HomeRequest()
    var pending: Pending?
}

enum HomeTab: Hashable {
    case automation
    case mcp
    case settings
}

struct HomeView: View {
    @State private var selection: HomeTab = .automation
    #if os(iOS)
    private let server = ServerController.shared
    #endif
    private let homeRequest = HomeRequest.shared

    var body: some View {
        layout
            .modifier(StorageNoticeAlert())
            .onChangeCompat(of: homeRequest.pending, initial: true) { pending in
                guard let pending else { return }
                homeRequest.pending = nil
                switch pending {
                case .settings: selection = .settings
                case .mcp: selection = .mcp
                }
            }
    }

    @ViewBuilder
    private var layout: some View {
        #if os(iOS)
        WithPerceptionTracking {
            if #available(iOS 18, *) {
                TabView(selection: $selection) {
                    Tab("Automation", systemImage: "wand.and.stars", value: HomeTab.automation) {
                        NavigationStackCompat {
                            automationView
                        }
                    }
                    Tab("MCP", systemImage: "server.rack", value: HomeTab.mcp) {
                        NavigationStackCompat {
                            mcpView
                        }
                    }
                    .badge(isMCPRunning ? Text(verbatim: "") : nil)
                    .accessibilityValue(Text("Running"), isEnabled: isMCPRunning)
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
                        mcpView
                    }
                    .tabItem { Label("MCP", systemImage: "server.rack") }
                    .tag(HomeTab.mcp)
                    .badge(isMCPRunning ? Text(verbatim: "") : nil)
                    .accessibilityValue(isMCPRunning ? Text("Running") : Text(verbatim: ""))
                    NavigationStackCompat {
                        SettingsView()
                    }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(HomeTab.settings)
                }
            }
        }
        #else
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { if let page = $0 { selection = page } })) {
                Label("Automation", systemImage: "wand.and.stars")
                    .tag(HomeTab.automation)
                Label("MCP", systemImage: "server.rack")
                    .tag(HomeTab.mcp)
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
                case .mcp:
                    ContentUnavailableView("Not Available on Mac", systemImage: "desktopcomputer")
                        .navigationTitle("MCP Server")
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
        if #available(iOS 27, *), ServerFeature.isAvailable {
            AutomationView()
        } else {
            ServerUnavailableView(title: "Automation")
        }
    }

    @ViewBuilder
    private var mcpView: some View {
        if ServerFeature.isAvailable {
            MCPView()
        } else {
            ServerUnavailableView(title: "MCP Server")
        }
    }

    private var isMCPRunning: Bool {
        server.phase.isRunning && server.isMCPActive
    }
    #endif
}
