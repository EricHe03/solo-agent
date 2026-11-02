import AuthenticationServices
import LibSwipt
import Perception
import SwiftUI
import UIKit

struct DeveloperView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LocalNetworkView()
                } label: {
                    PublishRow(icon: "wifi", title: Text("Local Network"), description: Text("Provides the Swipt API and MCP to the local network."))
                }
                NavigationLink {
                    CloudflareView()
                } label: {
                    PublishRow(
                        icon: "cloud", title: Text(verbatim: "Cloudflare"),
                        description: Text("Securely provides the Swipt API and MCP to the internet through Cloudflare."))
                }
            } header: {
                Text(verbatim: "API")
            }
        }
        .navigationTitle("Developer")
    }
}

private struct PublishRow: View {
    let icon: String
    let title: Text
    let description: Text

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                title
                description
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .font(.title2)
        }
        .padding(.vertical, 6)
    }
}

private struct LocalNetworkView: View {
    @State private var localHostName = LocalHostName()
    @State private var host = ""

    @Perception.Bindable private var settings = DeveloperSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.isLocalNetworkEnabled)
                }
                Section("Configuration") {
                    ValueRow(title: "Port", value: String(settings.localPort), keyboard: .numberPad) { text in
                        if let port = Int(text), DeveloperSettings.portRange.contains(port) {
                            settings.localPort = port
                        }
                    }
                }
                Section("Authentication") {
                    Toggle("Enabled", isOn: $settings.localAuthenticates)
                    if settings.localAuthenticates {
                        ValueRow(
                            title: "Token", value: settings.token, isSecret: true,
                            random: ("Random Token", { DeveloperSettings.randomHex(32) })
                        ) { text in
                            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !token.isEmpty {
                                settings.token = token
                            }
                        }
                    }
                }
                let hosts = localHostName.hosts
                if !hosts.isEmpty {
                    let selected = hosts.contains(host) ? host : hosts[0]
                    let address = "\(selected):\(settings.localPort)"
                    let token = settings.localAuthenticates ? settings.token : nil
                    UsageSection(title: Text(verbatim: "Swipt API")) {
                        Picker("Host", selection: Binding(get: { selected }, set: { host = $0 })) {
                            ForEach(hosts, id: \.self) { host in
                                Text(verbatim: host).tag(host)
                            }
                        }
                        .pickerStyle(.menu)
                    } items: { revealed in
                        apiUsage(scheme: "http", address: address, token: token, revealed: revealed)
                    }
                    UsageSection(title: Text(verbatim: "MCP")) {
                    } items: { revealed in
                        mcpUsage(scheme: "http", address: address, token: token, revealed: revealed)
                    }
                }
            }
            .navigationTitle("Local Network")
            .onAppear {
                localHostName.start()
            }
            .onDisappear {
                localHostName.stop()
            }
        }
    }
}

private struct CloudflareView: View {
    @State private var isLoggingIn = false
    @State private var isLoggingOut = false
    @State private var alert: AlertState?

    @Perception.Bindable private var settings = DeveloperSettings.shared

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section {
                    Toggle("Enabled", isOn: $settings.isCloudflareEnabled)
                        .disabled(!settings.isCloudflareEnabled && !settings.isCloudflareComplete)
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
                        random: ("Random Path", { "/\(DeveloperSettings.randomHex(16))" })
                    ) { text in
                        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        while path.hasSuffix("/") {
                            path.removeLast()
                        }
                        settings.cloudflarePath = path.hasPrefix("/") ? path : "/" + path
                    }
                }
                .disabled(settings.isCloudflareEnabled)
                Section("Authentication") {
                    ValueRow(
                        title: "Token", value: settings.token, isSecret: true,
                        random: ("Random Token", { DeveloperSettings.randomHex(32) })
                    ) { text in
                        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !token.isEmpty {
                            settings.token = token
                        }
                    }
                }
                let hostname = settings.cloudflarePublicHostname
                if !hostname.isEmpty {
                    let address = { (revealed: Bool) in "\(maskedHost(hostname, revealed: revealed))\(settings.cloudflarePathPrefix)" }
                    UsageSection(title: Text(verbatim: "Swipt API")) {
                    } items: { revealed in
                        apiUsage(scheme: "https", address: address(revealed), token: settings.token, revealed: revealed)
                    }
                    UsageSection(title: Text(verbatim: "MCP")) {
                    } items: { revealed in
                        mcpUsage(scheme: "https", address: address(revealed), token: settings.token, revealed: revealed)
                    }
                }
            }
            .navigationTitle(Text(verbatim: "Cloudflare"))
            .alert($alert)
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
                    settings.cloudflareHostname = "\(Platform.shared.hostLabel).\(account.zoneName)".lowercased()
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
    @Perception.Bindable private var settings = DeveloperSettings.shared

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

private func maskedToken(_ token: String) -> String {
    String(repeating: "•", count: min(token.count, 3))
}

private func maskedHost(_ host: String, revealed: Bool) -> String {
    revealed || !host.hasSuffix(".trycloudflare.com") ? host : "***" + host.drop { $0 != "." }
}

private func apiURL(scheme: String, address: String, token: String?, revealed: Bool) -> String {
    let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let credentials = token.map { (revealed ? $0.addingPercentEncoding(withAllowedCharacters: unreserved)! : maskedToken($0)) + "@" } ?? ""
    return "\(scheme)://\(credentials)\(address)"
}

private func apiUsage(scheme: String, address: String, token: String?, revealed: Bool) -> [UsageItem] {
    let url = apiURL(scheme: scheme, address: address, token: token, revealed: revealed)
    return [
        UsageItem(label: String(localized: "URL"), text: url),
        UsageItem(label: "Swipt CLI", text: "swipt connect \(url)"),
    ]
}

private func mcpUsage(scheme: String, address: String, token: String?, revealed: Bool) -> [UsageItem] {
    let url = apiURL(scheme: scheme, address: address, token: token, revealed: revealed) + LibSwiptAPIMCPPath
    let name = Platform.shared.hostLabel
    return [
        UsageItem(label: String(localized: "URL"), text: url),
        UsageItem(label: "Claude Code", text: "claude mcp add --transport http \(name) \(url)"),
        UsageItem(label: "Codex", text: "codex mcp add \(name) --url \(url)"),
    ]
}

private struct UsageItem {
    let label: String
    let text: String
}

private struct UsageSection<Leading: View>: View {
    let title: Text
    @ViewBuilder let leading: Leading
    let items: (_ revealed: Bool) -> [UsageItem]
    @State private var isRevealed = false

    var body: some View {
        WithPerceptionTracking {
            let commands = items(true)
            let displays = items(isRevealed)
            Section {
                leading
                ForEach(commands.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: commands[index].label)
                        CommandBlock(command: commands[index].text, display: displays[index].text)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    title
                    Spacer()
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(isRevealed ? Text("Hide") : Text("Show"))
                }
            }
        }
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
                    Text(verbatim: isSecret ? maskedToken(value) : value)
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
            return try await blocking { UncheckedSendable(value: try box.value.wait()) }.value
        } catch {
            if dismissed.withLock({ $0 }) { return nil }
            throw error
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private extension Platform {
    var hostLabel: String {
        let slug = name
            .filter { $0 != "'" && $0 != "’" }
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return slug.isEmpty ? UIDevice.current.model : slug
    }
}
