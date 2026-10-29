import Perception
import SwiftUI
import UIKit

struct MCPView: View {
    @FocusState private var isTokenFocused: Bool
    @State private var addresses: [String] = []
    @State private var localHostName = LocalHostName()
    @State private var host = ""

    private let controller = ServerController.shared
    @Perception.Bindable private var settings = ServerSettings.shared

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
                    PortField(port: $settings.mcpPort, defaultPort: ServerSettings.defaultMCPPort, range: ServerSettings.mcpPortRange)
                }
                .disabled(controller.isMCPActive)
                Section("Authentication") {
                    Toggle("Enabled", isOn: $settings.mcpAuthenticates)
                    if settings.mcpAuthenticates {
                        LabeledContentCompat("Token") {
                            TextField("Token", text: $settings.mcpToken.masked { isTokenFocused }, prompt: Text("Required"))
                                .textContentType(.oneTimeCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .multilineTextAlignment(.trailing)
                                .focused($isTokenFocused)
                                .submitLabel(.done)
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
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: "Claude Code")
                            CommandBlock(command: "claude mcp add --transport http \(serverName) \(url)")
                        }
                        .padding(.vertical, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: "Codex")
                            CommandBlock(command: "codex mcp add \(serverName) --url \(url)")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("MCP Server")
            .modifier(ServerScreen())
            .onAppear {
                addresses = Self.localAddresses()
                localHostName.start()
            }
            .onDisappear {
                localHostName.stop()
            }
        }
    }

    private var mcpBinding: Binding<Bool> {
        Binding(
            get: { controller.isMCPActive },
            set: { on in
                isTokenFocused = false
                controller.setMCP(on)
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

    private var serverName: String {
        let name = controller.name
            .filter { $0 != "'" && $0 != "’" }
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
        return name.isEmpty ? UIDevice.current.model : name
    }

    private var url: String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let credentials = settings.mcpAuthenticates ? settings.mcpToken.addingPercentEncoding(withAllowedCharacters: unreserved)! + "@" : ""
        return "http://\(credentials)\(selectedHost):\(settings.mcpPort)/mcp"
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

private struct PortField: View {
    @Binding var port: Int
    let defaultPort: Int
    let range: ClosedRange<Int>
    @State private var text: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        WithPerceptionTracking {
            LabeledContentCompat("Port") {
                TextField("Port", text: digits, prompt: Text(verbatim: String(defaultPort)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(isValid ? Color.primary : Color.red)
                    .focused($isFocused)
            }
            .onChangeCompat(of: isFocused) {
                if !isFocused {
                    text = nil
                }
            }
        }
    }

    private var digits: Binding<String> {
        Binding(
            get: { text ?? String(port) },
            set: { input in
                let digits = String(input.filter { $0.isASCII && $0.isNumber }.prefix(5))
                text = digits
                if let port = parsed(digits) {
                    self.port = port
                }
            })
    }

    private var isValid: Bool {
        text.map { parsed($0) != nil } ?? true
    }

    private func parsed(_ digits: String) -> Int? {
        guard !digits.isEmpty else { return defaultPort }
        guard let port = Int(digits), range.contains(port) else { return nil }
        return port
    }
}

private struct CommandBlock: View {
    let command: String
    @State private var isCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(verbatim: command)
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
