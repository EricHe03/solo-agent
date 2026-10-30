import AppIntents
import LibSwipt
import UniformTypeIdentifiers

@available(iOS 27, *)
enum ServiceOperation: String, AppEnum {
    case turnOn
    case turnOff
    case toggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Operation"
    static let caseDisplayRepresentations: [ServiceOperation: DisplayRepresentation] = [
        .turnOn: "Turn On",
        .turnOff: "Turn Off",
        .toggle: "Toggle",
    ]
}

@available(iOS 27, *)
struct SwipletActionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Swiplet Action"
    static let defaultQuery = SwipletActionQuery()

    let swiplet: String
    let swipletTitle: String
    let action: String
    let title: String

    var id: String { "\(swiplet)/\(action)" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(swipletTitle)")
    }
}

@available(iOS 27, *)
struct SwipletActionQuery: EntityStringQuery {
    @MainActor private var all: [SwipletActionEntity] {
        let store = SwipletStore.shared
        store.reload()
        return store.ids.flatMap { id in
            (store.actions[id] ?? []).filter(\.shortcuts).map {
                SwipletActionEntity(swiplet: id, swipletTitle: store.titles[id] ?? id, action: $0.name, title: $0.title)
            }
        }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [SwipletActionEntity] {
        let all = all
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor func entities(matching string: String) async throws -> [SwipletActionEntity] {
        all.filter { $0.title.localizedStandardContains(string) || $0.swipletTitle.localizedStandardContains(string) }
    }

    @MainActor func suggestedEntities() async throws -> [SwipletActionEntity] {
        all
    }
}

@available(iOS 27, *)
struct RunSwipletActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Swiplet Action"
    static let description = IntentDescription("Runs an action of a swiplet with the input as JSON, and returns its output as JSON.")

    @Parameter(title: "Action")
    var action: SwipletActionEntity

    @Parameter(
        title: "Input",
        inputOptions: String.IntentInputOptions(capitalizationType: .none, multiline: true, autocorrect: false, smartQuotes: false, smartDashes: false))
    var input: String?

    @Parameter(title: "Value")
    var dialogValue: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action)") {
            \.$input
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(
            value: try await Platform.shared.callAction(
                action.swiplet, action: action.action, input: input ?? "", caller: LibSwiptCallerShortcuts,
                dialogs: .intent { try await self.present($0, value: self.$dialogValue) }))
    }
}

@available(iOS 27, *)
struct SwipletServiceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Swiplet"
    static let defaultQuery = SwipletServiceQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

@available(iOS 27, *)
struct SwipletServiceQuery: EntityStringQuery {
    @MainActor private var all: [SwipletServiceEntity] {
        let store = SwipletStore.shared
        store.reload()
        return store.ids.filter(store.withServices.contains).map { SwipletServiceEntity(id: $0, title: store.titles[$0] ?? $0) }
    }

    @MainActor func entities(for identifiers: [String]) async throws -> [SwipletServiceEntity] {
        let all = all
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor func entities(matching string: String) async throws -> [SwipletServiceEntity] {
        all.filter { $0.title.localizedStandardContains(string) }
    }

    @MainActor func suggestedEntities() async throws -> [SwipletServiceEntity] {
        all
    }
}

@available(iOS 27, *)
struct SetSwipletServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Swiplet Service"
    static let description = IntentDescription("Turns the service of a swiplet on or off, and returns whether it’s on afterwards.")

    @Parameter(title: "Operation", default: .toggle)
    var operation: ServiceOperation

    @Parameter(title: "Swiplet")
    var swiplet: SwipletServiceEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$operation) \(\.$swiplet)")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let store = SwipletStore.shared
        let on =
            switch operation {
            case .turnOn: true
            case .turnOff: false
            case .toggle: !store.service(of: swiplet.id).enabled
            }
        try await store.setServiceEnabled(swiplet.id, on)
        return .result(value: on)
    }
}

@available(iOS 27, *)
struct SwiptShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSwipletActionIntent(),
            phrases: ["Run a swiplet action in \(.applicationName)"],
            shortTitle: "Run Swiplet Action",
            systemImageName: "play")
        AppShortcut(
            intent: SetSwipletServiceIntent(),
            phrases: ["Toggle a swiplet service in \(.applicationName)"],
            shortTitle: "Set Swiplet Service",
            systemImageName: "power")
    }
}
