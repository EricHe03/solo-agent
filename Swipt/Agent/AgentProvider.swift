import Foundation
import Perception
import Security

@Perceptible
final class AgentSettings {
    static let shared = AgentSettings()

    private enum Key {
        static let baseURL = "agent.provider.baseURL"
        static let model = "agent.provider.model"
        static let maximumSteps = "agent.maximumSteps"
        static let actionTimeout = "agent.actionTimeoutSeconds"
        static let observationRetries = "agent.observationRetries"
    }

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: Key.baseURL) }
    }
    var model: String {
        didSet { defaults.set(model, forKey: Key.model) }
    }
    var maximumSteps: Int {
        didSet { defaults.set(maximumSteps, forKey: Key.maximumSteps) }
    }
    var actionTimeoutSeconds: Int {
        didSet { defaults.set(actionTimeoutSeconds, forKey: Key.actionTimeout) }
    }
    var observationRetries: Int {
        didSet { defaults.set(observationRetries, forKey: Key.observationRetries) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        baseURL = defaults.string(forKey: Key.baseURL) ?? "https://api.openai.com/v1"
        model = defaults.string(forKey: Key.model) ?? "gpt-5.2"
        maximumSteps = max(1, min(100, defaults.object(forKey: Key.maximumSteps) as? Int ?? 25))
        actionTimeoutSeconds = max(5, min(120, defaults.object(forKey: Key.actionTimeout) as? Int ?? 25))
        observationRetries = max(0, min(3, defaults.object(forKey: Key.observationRetries) as? Int ?? 1))
    }
}

enum AgentKeychain {
    private static let account = "openai-compatible"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "SoloAgent",
            kSecAttrAccount as String: account,
        ]
    }

    static func apiKey() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AgentAPIError(message: "The API key could not be read from Keychain (status \(status)).")
        }
        return key
    }

    static func saveAPIKey(_ key: String) throws {
        if key.isEmpty {
            let query = baseQuery
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AgentAPIError(message: "The API key could not be removed from Keychain (status \(status)).")
            }
            return
        }
        var query = baseQuery
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentAPIError(message: "The API key could not be saved to Keychain (status \(status)).")
        }
    }
}

struct OpenAICompatibleClient: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String

    func complete(messages: [AgentChatMessage], tools: [AgentToolDefinition]?) async throws -> AgentChatResponse {
        let endpoint = try chatCompletionsURL()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentAPIError(message: "Add an API key in AI Provider settings first.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AgentChatRequest(model: model, messages: messages, tools: tools, toolChoice: tools == nil ? nil : "auto", stream: false))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentAPIError(message: "The AI provider could not be reached: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw AgentAPIError(message: "The AI provider returned an invalid response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(4096), encoding: .utf8) ?? "No response body"
            throw AgentAPIError(message: "The AI provider returned HTTP \(http.statusCode): \(body)")
        }
        do {
            let decoded = try JSONDecoder().decode(AgentChatResponse.self, from: data)
            guard !decoded.choices.isEmpty else {
                throw AgentAPIError(message: "The AI provider returned no choices.")
            }
            return decoded
        } catch let error as AgentAPIError {
            throw error
        } catch {
            throw AgentAPIError(message: "The AI provider response was not valid Chat Completions JSON: \(error.localizedDescription)")
        }
    }

    func testConnectivity() async throws -> String {
        let response = try await complete(messages: [.text("user", "Reply with exactly OK.")], tools: nil)
        return response.choices[0].message.content?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Connected"
    }

    private func chatCompletionsURL() throws -> URL {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if !value.hasSuffix("/chat/completions") {
            value += "/chat/completions"
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), scheme == "https", url.host != nil else {
            throw AgentAPIError(message: "Use a valid HTTPS API base URL, for example https://api.openai.com/v1.")
        }
        return url
    }
}
