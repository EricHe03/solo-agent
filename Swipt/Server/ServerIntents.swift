import AppIntents
import LibSwipt
import UniformTypeIdentifiers

@available(iOS 27, *)
enum ServerOperation: String, AppEnum {
    case turnOn
    case turnOff
    case toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Operation"
    static let caseDisplayRepresentations: [ServerOperation: DisplayRepresentation] = [
        .turnOn: "Turn On",
        .turnOff: "Turn Off",
        .toggle: "Toggle",
    ]
}

@available(iOS 27, *)
enum MCPServerKind: String, AppEnum {
    case local
    case cloudflare

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let caseDisplayRepresentations: [MCPServerKind: DisplayRepresentation] = [
        .local: "Local Server",
        .cloudflare: "Cloudflare",
    ]

    @MainActor var isActive: Bool {
        switch self {
        case .local: ServerController.shared.isLocalMCPActive
        case .cloudflare: ServerController.shared.isCloudflareMCPActive
        }
    }
}

@available(iOS 27, *)
struct SetMCPServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set MCP Server"
    static let description = IntentDescription("Turns MCP Server on or off, and returns whether it’s on afterwards. Turning it on waits until it’s running.")

    @Parameter(title: "Operation", default: .toggle)
    var operation: ServerOperation

    @Parameter(title: "Server", default: .local)
    var server: MCPServerKind

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$operation) \(\.$server)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let controller = ServerController.shared
        let settings = ServerSettings.shared
        let on =
            switch operation {
            case .turnOn: true
            case .turnOff: false
            case .toggle: !server.isActive
            }
        let set = server == .local ? controller.setLocalMCP : controller.setCloudflareMCP
        guard on else {
            set(false)
            return .result(value: false)
        }
        if !server.isActive {
            if let problem = controller.startProblem {
                throw MessageError(problem)
            }
            if !(server == .local ? settings.isLocalMCPComplete : settings.isCloudflareComplete) {
                throw MessageError(String(localized: "Complete the MCP Server settings."))
            }
            set(true)
        }
        try await controller.waitUntilRunning()
        return .result(value: true)
    }
}

@available(iOS 27, *)
struct GetMCPServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Get MCP Server Status"
    static let description = IntentDescription("Returns whether MCP Server is on.")

    @Parameter(title: "Server", default: .local)
    var server: MCPServerKind

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: server.isActive)
    }
}

@available(iOS 27, *)
struct ScriptResult: TransientAppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Script Result"

    @Property(title: "Text")
    var text: String

    @Property(title: "Screenshots")
    var screenshots: [IntentFile]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)", image: screenshots.first.map { DisplayRepresentation.Image(data: $0.data) })
    }

    init() {}

    init(_ output: ScriptOutput) {
        text = output.text
        screenshots = output.images.enumerated().map { index, data in
            IntentFile(data: data, filename: "Screenshot \(index + 1).png", type: .png)
        }
    }
}

@available(iOS 27, *)
struct RunScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Script"
    static let description = IntentDescription(
        "Runs JavaScript with top-level await in the session of the MCP server’s js tool, where the phone object controls this device. Get Script API returns the declarations of phone and the other globals; use only what they describe. Top-level bindings persist across runs while MCP Server is on; with it off, the app connects to this device just for the run. Returns a script result whose text is the value of the last expression statement and anything passed to print, and whose screenshots are the images that phone.screenshot() took.")

    @Parameter(
        title: "Script",
        inputOptions: String.IntentInputOptions(capitalizationType: .none, multiline: true, autocorrect: false, smartQuotes: false, smartDashes: false))
    var script: String

    @Parameter(title: "Value")
    var dialogValue: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$script)") {}
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ScriptResult> {
        .result(value: ScriptResult(try await ServerController.shared.runScript(script, dialogs: .intent { try await self.present($0, value: self.$dialogValue) })))
    }
}

@available(iOS 27, *)
struct WorkflowEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Workflow"
    static let defaultQuery = WorkflowQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

@available(iOS 27, *)
struct WorkflowQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [WorkflowEntity] {
        WorkflowStore.shared.reload()
        return identifiers.filter(WorkflowStore.shared.names.contains).map(WorkflowEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [WorkflowEntity] {
        WorkflowStore.shared.reload()
        return WorkflowStore.shared.names.filter { $0.localizedStandardContains(string) }.map(WorkflowEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [WorkflowEntity] {
        WorkflowStore.shared.reload()
        return WorkflowStore.shared.names.map(WorkflowEntity.init)
    }
}

@available(iOS 27, *)
struct RunWorkflowIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Workflow"
    static let description = IntentDescription(
        "Runs a workflow from main.js in its source files, in a new JavaScript context where the phone object controls this device. With MCP Server off, the app connects to this device just for the run. The run fails if the workflow is already running. Returns a script result whose text is the default export of main.js.")

    @Parameter(title: "Workflow")
    var workflow: WorkflowEntity

    @Parameter(title: "Value")
    var dialogValue: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$workflow)") {}
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<ScriptResult> {
        .result(value: ScriptResult(try await ServerController.shared.runWorkflow(workflow.id, dialogs: .intent { try await self.present($0, value: self.$dialogValue) })))
    }
}

@available(iOS 27, *)
struct GetScriptAPIIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Script API"
    static let description = IntentDescription("Returns the TypeScript declarations of phone and the other globals that Run Script provides.")

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: LibSwiptScriptAPI())
    }
}

@available(iOS 27, *)
struct ResetScriptIntent: AppIntent {
    static let title: LocalizedStringResource = "Reset Script"
    static let description = IntentDescription("Interrupts the scripts in progress and clears the top-level bindings of earlier ones, as the MCP server’s js_reset tool does.")

    @MainActor func perform() async throws -> some IntentResult {
        try await ServerController.shared.resetScript()
        return .result()
    }
}

@available(iOS 27, *)
struct ServerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetMCPServerIntent(),
            phrases: ["Toggle MCP Server in \(.applicationName)"],
            shortTitle: "Toggle MCP Server",
            systemImageName: "power")
        AppShortcut(
            intent: GetMCPServerIntent(),
            phrases: ["Get the status of MCP Server in \(.applicationName)"],
            shortTitle: "Get MCP Server Status",
            systemImageName: "server.rack")
        AppShortcut(
            intent: RunScriptIntent(),
            phrases: ["Run a script in \(.applicationName)"],
            shortTitle: "Run Script",
            systemImageName: "curlybraces")
        AppShortcut(
            intent: RunWorkflowIntent(),
            phrases: ["Run a workflow in \(.applicationName)"],
            shortTitle: "Run Workflow",
            systemImageName: "play")
        AppShortcut(
            intent: ResetScriptIntent(),
            phrases: ["Reset the script in \(.applicationName)"],
            shortTitle: "Reset Script",
            systemImageName: "arrow.counterclockwise")
    }
}
