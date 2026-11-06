import Perception
import SwiftUI

struct AgentHomeView: View {
    var body: some View {
        WithPerceptionTracking {
            if Platform.isSupported, SetupView.isNeeded {
                SetupView()
                    .modifier(ErrorAlertPresenter())
            } else {
                TabView {
                    NavigationStack { AgentChatView() }
                        .tabItem { Label("Agent", systemImage: "sparkles") }
                    NavigationStack { AgentDeviceView() }
                        .tabItem { Label("Device", systemImage: "iphone") }
                    NavigationStack { AgentSettingsView() }
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                }
                .modifier(ErrorAlertPresenter())
            }
        }
    }
}

struct AgentChatView: View {
    private let agent = AgentController.shared

    var body: some View {
        WithPerceptionTracking {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(agent.messages) { message in
                            AgentMessageBubble(message: message)
                                .id(message.id)
                        }
                        if agent.state.isActive {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(agent.currentAction)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal)
                        }
                        executionLog
                    }
                    .padding()
                }
                .onChangeCompat(of: agent.messages.count) { _ in
                    if let last = agent.messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("Solo Agent")
            .safeAreaInset(edge: .bottom) { composer }
            .alert(item: Binding(get: { agent.confirmation }, set: { _ in })) { confirmation in
                Alert(
                    title: Text(confirmation.title),
                    message: Text(confirmation.message),
                    primaryButton: .default(Text("Allow Once")) { agent.answerConfirmation(true) },
                    secondaryButton: .cancel(Text("Don’t Allow")) { agent.answerConfirmation(false) }
                )
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask Solo Agent…", text: Binding(get: { agent.input }, set: { agent.input = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .disabled(agent.state.isActive)
                .onSubmit { agent.send() }
            if agent.state.isActive {
                Button(role: .destructive) { agent.stop() } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Stop task")
            } else {
                Button { agent.send() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 34))
                }
                .disabled(agent.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send task")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var executionLog: some View {
        DisclosureGroup(isExpanded: Binding(get: { agent.showsLogs }, set: { agent.showsLogs = $0 })) {
            if agent.logs.isEmpty {
                Text("Actions and verification results will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(agent.logs) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: icon(for: entry.level))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.title).font(.callout.bold())
                            Spacer()
                            Text(entry.date.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        } label: {
            Label("Execution log (\(agent.logs.count))", systemImage: "list.bullet")
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func icon(for level: AgentLogEntry.Level) -> String {
        switch level {
        case .info: "info.circle"
        case .action: "hand.tap"
        case .success: "checkmark.circle"
        case .failure: "exclamationmark.triangle"
        }
    }

    private func color(for level: AgentLogEntry.Level) -> Color {
        switch level {
        case .info: .secondary
        case .action: .accentColor
        case .success: .green
        case .failure: .orange
        }
    }
}

private struct AgentMessageBubble: View {
    let message: AgentChatItem

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 36) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role != .user { Spacer(minLength: 36) }
        }
    }
}
