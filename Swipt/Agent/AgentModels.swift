import Foundation

struct AgentChatItem: Identifiable, Equatable {
    enum Role: Equatable {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    let text: String
}

struct AgentLogEntry: Identifiable, Equatable {
    enum Level: Equatable {
        case info
        case action
        case success
        case failure
    }

    let id = UUID()
    let date = Date()
    let level: Level
    let title: String
    let detail: String
}

enum AgentRunState: Equatable {
    case idle
    case running
    case awaitingConfirmation
    case succeeded
    case failed
    case cancelled

    var isActive: Bool {
        self == .running || self == .awaitingConfirmation
    }
}

struct AgentConfirmation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

struct AgentToolDefinition: Codable, Sendable {
    let type: String
    let function: AgentFunctionDefinition
}

struct AgentFunctionDefinition: Codable, Sendable {
    let name: String
    let description: String
    let parameters: AgentJSONValue
}

indirect enum AgentJSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: AgentJSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([AgentJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct AgentToolCall: Codable, Sendable {
    struct Function: Codable, Sendable {
        let name: String
        let arguments: String
    }

    let id: String
    let type: String
    let function: Function
}

enum AgentMessageContent: Codable, Sendable {
    case text(String)
    case parts([AgentContentPart])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([AgentContentPart].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .parts(let parts): try container.encode(parts)
        }
    }

    var plainText: String {
        switch self {
        case .text(let text): text
        case .parts(let parts): parts.compactMap { $0.text }.joined(separator: "\n")
        }
    }
}

struct AgentContentPart: Codable, Sendable {
    struct ImageURL: Codable, Sendable {
        let url: String
        let detail: String?
    }

    let type: String
    let text: String?
    let imageURL: ImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func text(_ value: String) -> AgentContentPart {
        AgentContentPart(type: "text", text: value, imageURL: nil)
    }

    static func image(base64PNG: String) -> AgentContentPart {
        AgentContentPart(type: "image_url", text: nil, imageURL: ImageURL(url: "data:image/png;base64,\(base64PNG)", detail: "high"))
    }
}

struct AgentChatMessage: Codable, Sendable {
    let role: String
    let content: AgentMessageContent?
    let toolCalls: [AgentToolCall]?
    let toolCallID: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    static func text(_ role: String, _ text: String) -> AgentChatMessage {
        AgentChatMessage(role: role, content: .text(text), toolCalls: nil, toolCallID: nil, name: nil)
    }

    static func tool(id: String, name: String, content: String) -> AgentChatMessage {
        AgentChatMessage(role: "tool", content: .text(content), toolCalls: nil, toolCallID: id, name: name)
    }

    static func imageObservation(_ text: String, base64PNG: String) -> AgentChatMessage {
        AgentChatMessage(role: "user", content: .parts([.text(text), .image(base64PNG: base64PNG)]), toolCalls: nil, toolCallID: nil, name: nil)
    }
}

struct AgentChatRequest: Encodable, Sendable {
    let model: String
    let messages: [AgentChatMessage]
    let tools: [AgentToolDefinition]?
    let toolChoice: String?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream
        case toolChoice = "tool_choice"
    }
}

struct AgentChatResponse: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            let content: AgentMessageContent?
            let toolCalls: [AgentToolCall]?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
            }
        }

        let message: Message
    }

    let choices: [Choice]
}

struct AgentAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
