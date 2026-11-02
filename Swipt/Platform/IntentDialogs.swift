import AppIntents

@available(iOS 27, *)
extension AppIntent {
    func present(_ request: DialogRequest, value parameter: IntentParameter<String?>) async throws -> DialogAnswer {
        let dialog = request.prompt.map { IntentDialog(.verbatim($0)) }
        switch request {
        case .choice(_, let options):
            let chosen = try await requestChoice(between: DialogRequest.Choice.intentOptions(options), dialog: dialog)
            return .index(options.firstIndex { $0.intentOption == chosen } ?? 0)
        case .confirmation(let prompt, let action):
            let actionName: ConfirmationActionName =
                switch action {
                case .named(let name): name.intentName
                case .custom(let accept, let deny, let destructive):
                    .custom(acceptLabel: .verbatim(accept), acceptAlternatives: [], denyLabel: .verbatim(deny), denyAlternatives: [], destructive: destructive)
                }
            try await requestConfirmation(actionName: actionName, dialog: IntentDialog(.verbatim(prompt)))
            return .none
        // Shortcuts asks only for parameters its editor shows
        // (-[WFSequentialParameterInputProvider askForParameterIfAvailable], iOS 27 24A446).
        case .value:
            return try await ScriptDialogs.shared.present(request)
        case .disambiguation(_, let values):
            let chosen = try await parameter.requestDisambiguation(among: values, dialog: dialog)
            return .index(values.firstIndex(of: chosen) ?? 0)
        case .valueConfirmation(_, let value):
            return .confirmed(try await parameter.requestConfirmation(for: value, dialog: dialog))
        // Declaring a foreground mode for continueInForeground gives every action an Open When Run switch that starts on
        // (-[WFLinkAction parameterDefinitions], iOS 27 24A446), so the engine brings the app forward itself.
        case .foreground(let prompt, let alwaysConfirm):
            if alwaysConfirm {
                let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ""
                let text = prompt ?? String(localized: "Continue in \(name)?")
                try await requestConfirmation(actionName: .open, dialog: IntentDialog(.verbatim(text)))
            }
            return .none
        }
    }
}

@available(iOS 27, *)
extension DialogRequest.Choice {
    nonisolated var intentOption: IntentChoiceOption {
        let style: IntentChoiceOption.Style =
            switch style {
            case .default: .default
            case .destructive: .destructive
            case .cancel: .cancel
            }
        return IntentChoiceOption(title: .verbatim(title), style: style)
    }

    nonisolated static func intentOptions(_ choices: [Self]) -> [IntentChoiceOption] {
        choices.map(\.intentOption)
    }
}

@available(iOS 27, *)
extension DialogRequest.ActionName {
    var intentName: ConfirmationActionName {
        switch self {
        case .add: .add
        case .addData: .addData
        case .book: .book
        case .buy: .buy
        case .call: .call
        case .checkIn: .checkIn
        case .continue: .continue
        case .create: .create
        case .do: .do
        case .download: .download
        case .filter: .filter
        case .find: .find
        case .get: .get
        case .go: .go
        case .log: .log
        case .open: .open
        case .order: .order
        case .pay: .pay
        case .play: .play
        case .playSound: .playSound
        case .post: .post
        case .request: .request
        case .run: .run
        case .search: .search
        case .send: .send
        case .set: .set
        case .share: .share
        case .start: .start
        case .startNavigation: .startNavigation
        case .toggle: .toggle
        case .turnOff: .turnOff
        case .turnOn: .turnOn
        case .view: .view
        }
    }
}

extension LocalizedStringResource {
    /// Shows a runtime string as is: nothing is extracted into a String Catalog,
    /// and the lookup goes to a table that doesn't exist so no key can match.
    nonisolated static func verbatim(_ string: String) -> LocalizedStringResource {
        LocalizedStringResource(String.LocalizationValue(string), table: "Verbatim")
    }
}
