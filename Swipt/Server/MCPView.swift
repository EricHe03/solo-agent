import AuthenticationServices
import LibSwipt
import Perception
import SwiftUI
import UIKit

struct MCPView: View {
    private let controller = ServerController.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle("Enabled", isOn: mcpBinding)
                        .disabled(!controller.isMCPActive && !controller.canStartMCP)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        ServerStatus()
                    }
                }
                Section("Listen") {
                    NavigationLink("Local") {
                        LocalMCPView()
                    }
                    NavigationLink {
                        CloudflareMCPView()
                    } label: {
                        Text(verbatim: "Cloudflare")
                    }
                }
            }
            .navigationTitle("MCP Server")
            .modifier(ServerScreen())
        }
    }

    private var mcpBinding: Binding<Bool> {
        Binding(get: { controller.isMCPActive }, set: { controller.setMCP($0) })
    }
}

private struct LocalMCPView: View {
    @State private var addresses: [String] = []
    @State private var localHostName = LocalHostName()
    @State private var host = ""

    private let controller = ServerController.shared
    @Perception.Bindable private var settings = ServerSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Group {
                    Section {
                        Toggle("Enabled", isOn: $settings.isLocalMCPEnabled)
                    }
                    Section("Configuration") {
                        ValueRow(title: "Port", value: String(settings.mcpPort), keyboard: .numberPad) { text in
                            if let port = Int(text), ServerSettings.mcpPortRange.contains(port) {
                                settings.mcpPort = port
                            }
                        }
                    }
                    Section("Authentication") {
                        Toggle("Enabled", isOn: authenticatesBinding)
                        if settings.mcpAuthenticates {
                            ValueRow(
                                title: "Token", value: settings.mcpToken, isSecret: true,
                                random: ("Random Token", { ServerSettings.randomHex(32) })
                            ) {
                                settings.mcpToken = $0
                            }
                        }
                    }
                }
                .disabled(controller.isMCPActive)
                if !hosts.isEmpty {
                    Section("Usage") {
                        Picker("Host", selection: hostBinding) {
                            ForEach(hosts, id: \.self) { host in
                                Text(verbatim: host).tag(host)
                            }
                        }
                        .pickerStyle(.menu)
                        MCPCommands(
                            scheme: "http", token: settings.mcpAuthenticates ? settings.mcpToken : nil,
                            host: "\(selectedHost):\(settings.mcpPort)", path: "/mcp")
                    }
                }
            }
            .navigationTitle("Local")
            .onAppear {
                addresses = Self.localAddresses()
                localHostName.start()
            }
            .onDisappear {
                localHostName.stop()
            }
        }
    }

    private var authenticatesBinding: Binding<Bool> {
        Binding(
            get: { settings.mcpAuthenticates },
            set: { on in
                settings.mcpAuthenticates = on
                if on, settings.mcpToken.isEmpty {
                    settings.mcpToken = ServerSettings.randomHex(32)
                }
            })
    }

    private var hosts: [String] {
        (localHostName.name.map { [$0] } ?? []) + addresses
    }

    private var selectedHost: String {
        hosts.contains(host) ? host : hosts.first ?? ""
    }

    private var hostBinding: Binding<String> {
        Binding(get: { selectedHost }, set: { host = $0 })
    }

    private static func localAddresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var hosts: [(host: String, lan: Bool)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            let interface = String(cString: entry.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, !interface.hasPrefix("pdp_ip"), !interface.hasPrefix("ipsec"),
                let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            hosts.append((String(cString: buffer), interface.hasPrefix("en")))
        }
        return hosts.sorted { $0.lan && !$1.lan }.map(\.host)
    }
}

private struct CloudflareMCPView: View {
    @State private var isLoggingIn = false
    @State private var isLoggingOut = false
    @State private var alert: AlertState?

    private let controller = ServerController.shared
    @Perception.Bindable private var settings = ServerSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Group {
                    Section {
                        Toggle("Enabled", isOn: $settings.isCloudflareEnabled)
                    }
                    Section("Configuration") {
                        NavigationLink {
                            CloudflareModeView()
                        } label: {
                            LabeledContentCompat("Mode") {
                                Text(verbatim: settings.cloudflareMode.name)
                            }
                        }
                        if settings.cloudflareMode == .tunnel {
                            if settings.cloudflareAccount.isEmpty {
                                Button("Log In", action: logIn)
                                    .disabled(isLoggingIn)
                            } else {
                                Button {
                                    isLoggingOut = true
                                } label: {
                                    LabeledContentCompat("Account") {
                                        Text(verbatim: settings.cloudflareZone)
                                    }
                                }
                                .foregroundStyle(.primary)
                                .confirmationDialog("Account", isPresented: $isLoggingOut) {
                                    Button("Log Out", role: .destructive, action: logOut)
                                }
                            }
                            ValueRow(title: "Domain", value: settings.cloudflareHostname, keyboard: .URL) {
                                settings.cloudflareHostname = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            }
                        }
                        ValueRow(
                            title: "Prefix", value: settings.cloudflarePath, keyboard: .URL,
                            random: ("Random Path", { "/\(ServerSettings.randomHex(16))/mcp" })
                        ) { text in
                            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            settings.cloudflarePath = path.hasPrefix("/") ? path : "/" + path
                        }
                    }
                    Section("Authentication") {
                        ValueRow(
                            title: "Token", value: settings.cloudflareToken, isSecret: true,
                            random: ("Random Token", { ServerSettings.randomHex(32) })
                        ) {
                            settings.cloudflareToken = $0
                        }
                    }
                }
                .disabled(controller.isMCPActive)
                if !hostname.isEmpty {
                    Section("Usage") {
                        MCPCommands(scheme: "https", token: settings.cloudflareToken, host: hostname, path: settings.cloudflarePath)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Cloudflare"))
            .alert($alert)
        }
    }

    private var hostname: String {
        switch settings.cloudflareMode {
        case .quickTunnel: settings.isCloudflareEnabled ? settings.cloudflareQuickHostname : ""
        case .tunnel: settings.cloudflareHostname
        }
    }

    private func logIn() {
        isLoggingIn = true
        Task {
            defer { isLoggingIn = false }
            do {
                guard let account = try await CloudflareWebLogin().run() else { return }
                settings.cloudflareAccount = account.credential
                settings.cloudflareZone = account.zoneName
                settings.cloudflareNamedTunnel = ""
                if !account.zoneName.isEmpty {
                    settings.cloudflareHostname = "\(controller.serverName).\(account.zoneName)".lowercased()
                }
            } catch {
                alert = AlertState(String(localized: "Can’t Log In"), error: error)
            }
        }
    }

    private func logOut() {
        settings.cloudflareAccount = ""
        settings.cloudflareZone = ""
        settings.cloudflareNamedTunnel = ""
        settings.cloudflareHostname = ""
    }
}

private struct CloudflareModeView: View {
    @Perception.Bindable private var settings = ServerSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section("Mode") {
                    Picker("Mode", selection: $settings.cloudflareMode) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: CloudflareMode.quickTunnel.name)
                            Text("Uses a domain provided by Cloudflare, which is released when turned off.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(CloudflareMode.quickTunnel)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: CloudflareMode.tunnel.name)
                            Text("Uses your own account and domain.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(CloudflareMode.tunnel)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(Text(verbatim: "Cloudflare"))
        }
    }
}

private final class CloudflareWebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    func run() async throws -> LibSwiptCloudflareAccount? {
        guard let login = LibSwiptNewCloudflareLogin(), let url = URL(string: login.loginURL()) else { return nil }
        let box = UncheckedSendable(value: login)
        let dismissed = LockedState(initialState: false)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: nil) { @Sendable _, error in
            guard error != nil else { return }
            dismissed.withLock { $0 = true }
            box.value.cancel()
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        guard session.start() else {
            login.cancel()
            return nil
        }
        defer { session.cancel() }
        do {
            return try await Task.detached { UncheckedSendable(value: try box.value.wait()) }.value.value
        } catch {
            if dismissed.withLock({ $0 }) { return nil }
            throw error
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private extension ServerController {
    var serverName: String {
        let slug = name
            .filter { $0 != "'" && $0 != "’" }
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? UIDevice.current.model : slug
    }
}

private struct ValueRow: View {
    let title: LocalizedStringKey
    let value: String
    var isSecret = false
    var keyboard = UIKeyboardType.default
    var random: (title: LocalizedStringKey, make: () -> String)?
    let save: (String) -> Void
    @State private var text = ""
    @State private var isEditing = false

    var body: some View {
        Button {
            text = value
            isEditing = true
        } label: {
            LabeledContentCompat(title) {
                if value.isEmpty {
                    Text("Required")
                } else {
                    Text(verbatim: isSecret ? String(repeating: "•", count: min(value.count, 3)) : value)
                }
            }
        }
        .foregroundStyle(.primary)
        .alert(title, isPresented: $isEditing) {
            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let random {
                Button(random.title) { save(random.make()) }
            }
            Button("Cancel", role: .cancel) {}
            Button("OK") { save(text) }
        }
    }
}

private struct MCPCommands: View {
    let scheme: String
    let token: String?
    let host: String
    let path: String

    private let controller = ServerController.shared

    var body: some View {
        WithPerceptionTracking {
            let claude = "claude mcp add --transport http \(controller.serverName) "
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Claude Code")
                CommandBlock(command: claude + url(revealed: true), display: claude + url(revealed: false))
            }
            .padding(.vertical, 4)
            let codex = "codex mcp add \(controller.serverName) --url "
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "Codex")
                CommandBlock(command: codex + url(revealed: true), display: codex + url(revealed: false))
            }
            .padding(.vertical, 4)
        }
    }

    private func url(revealed: Bool) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let credentials = token.map {
            (revealed ? $0.addingPercentEncoding(withAllowedCharacters: unreserved)! : String(repeating: "•", count: min($0.count, 3))) + "@"
        } ?? ""
        return "\(scheme)://\(credentials)\(host)\(path)"
    }
}

private struct CommandBlock: View {
    let command: String
    let display: String
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: display)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = command
                isCopied = true
                Task {
                    try? await Task.sleep(seconds: 1.5)
                    isCopied = false
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Copy"))
        }
        .padding(10)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }
}
