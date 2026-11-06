import Perception
import SwiftUI

struct AgentSettingsView: View {
    private let settings = AgentSettings.shared
    @State private var apiKey = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testSucceeded = false

    var body: some View {
        WithPerceptionTracking {
            Form {
                Section("AI Provider") {
                    TextField("API base URL", text: Binding(get: { settings.baseURL }, set: { settings.baseURL = $0 }))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Model identifier", text: Binding(get: { settings.model }, set: { settings.model = $0 }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Button("OpenAI") {
                            settings.baseURL = "https://api.openai.com/v1"
                        }
                        Button("OpenRouter") {
                            settings.baseURL = "https://openrouter.ai/api/v1"
                        }
                    }
                    .buttonStyle(.borderless)
                    Button {
                        saveAndTest()
                    } label: {
                        HStack {
                            Text("Save Key & Test Connection")
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let testResult {
                        Label(testResult, systemImage: testSucceeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(testSucceeded ? Color.green : Color.red)
                    }
                } footer: {
                    Text("Use an OpenAI-compatible Chat Completions endpoint with tool calling. Consumer chat subscriptions do not necessarily include API access. The key is stored only in this device’s Keychain.")
                }

                Section("Agent Limits") {
                    Stepper("Maximum steps: \(settings.maximumSteps)", value: Binding(get: { settings.maximumSteps }, set: { settings.maximumSteps = $0 }), in: 1...100)
                    Stepper("Action timeout: \(settings.actionTimeoutSeconds) s", value: Binding(get: { settings.actionTimeoutSeconds }, set: { settings.actionTimeoutSeconds = $0 }), in: 5...120, step: 5)
                    Stepper("Observation retries: \(settings.observationRetries)", value: Binding(get: { settings.observationRetries }, set: { settings.observationRetries = $0 }), in: 0...3)
                }

                Section("Automation") {
                    NavigationLink("Background Service") { BackgroundView() }
                    NavigationLink("Automatic Unlock") { AutoUnlockView() }
                }

                Section("About") {
                    Link("Solo Agent Source Code", destination: URL(string: "https://github.com/EricHe03/solo-agent")!)
                    Link("Upstream Swipt Project", destination: URL(string: "https://github.com/swipt-automation/swipt")!)
                    Link("GNU GPLv3 License", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
                    Text("Solo Agent is an independent GPLv3 derivative and is not officially affiliated with Swipt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .task {
                apiKey = (try? AgentKeychain.apiKey()) ?? ""
            }
        }
    }

    private func saveAndTest() {
        testing = true
        testResult = nil
        Task {
            do {
                try AgentKeychain.saveAPIKey(apiKey)
                let client = OpenAICompatibleClient(baseURL: settings.baseURL, model: settings.model, apiKey: apiKey)
                let answer = try await client.testConnectivity()
                testSucceeded = true
                testResult = answer.isEmpty ? "Connection succeeded." : "Connection succeeded: \(answer)"
            } catch {
                testSucceeded = false
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
