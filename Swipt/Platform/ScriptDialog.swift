import CoreLocation
import Foundation

nonisolated enum DialogRequest: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        enum Style: String, Decodable, Sendable {
            case `default`
            case destructive
            case cancel
        }

        let title: String
        let style: Style
    }

    enum ActionName: String, Decodable, Sendable {
        case add, addData, book, buy, call, checkIn, `continue`, create, `do`, download, filter, find, get, go, log, open, order, pay
        case play, playSound, post, request, run, search, send, set, share, start, startNavigation, toggle, turnOff, turnOn, view
    }

    enum ConfirmationAction: Decodable, Sendable {
        case named(ActionName)
        case custom(accept: String, deny: String, destructive: Bool)

        private enum CodingKeys: String, CodingKey {
            case accept, deny, destructive
        }

        init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(ActionName.self) {
                self = .named(name)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self = .custom(
                accept: try container.decode(String.self, forKey: .accept),
                deny: try container.decode(String.self, forKey: .deny),
                destructive: try container.decode(Bool.self, forKey: .destructive))
        }
    }

    enum Field: Sendable {
        case text(multiline: Bool, literal: Bool)
        case integer(stepper: Bool, min: Int?, max: Int?)
        case number(min: Double?, max: Double?)
        case date
        case time
        case dateTime
        case file
        case person
        case placemark
    }

    case choice(prompt: String?, options: [Choice])
    case confirmation(prompt: String, action: ConfirmationAction)
    case value(prompt: String?, field: Field)
    case disambiguation(prompt: String?, values: [String])
    case valueConfirmation(prompt: String?, value: String)

    private enum CodingKeys: String, CodingKey {
        case kind, prompt, options, actionName, type, multiline, literal, stepper, min, max, values, value
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        switch try container.decode(String.self, forKey: .kind) {
        case "choice":
            self = .choice(prompt: prompt, options: try container.decode([Choice].self, forKey: .options))
        case "confirmation":
            self = .confirmation(prompt: prompt ?? "", action: try container.decode(ConfirmationAction.self, forKey: .actionName))
        case "value":
            let field: Field
            switch try container.decode(String.self, forKey: .type) {
            case "text":
                field = .text(multiline: try container.decode(Bool.self, forKey: .multiline), literal: try container.decode(Bool.self, forKey: .literal))
            case "integer":
                field = .integer(
                    stepper: try container.decode(Bool.self, forKey: .stepper),
                    min: try container.decodeIfPresent(Int.self, forKey: .min),
                    max: try container.decodeIfPresent(Int.self, forKey: .max))
            case "number":
                field = .number(min: try container.decodeIfPresent(Double.self, forKey: .min), max: try container.decodeIfPresent(Double.self, forKey: .max))
            case "date": field = .date
            case "time": field = .time
            case "dateTime": field = .dateTime
            case "file": field = .file
            case "person": field = .person
            case "placemark": field = .placemark
            case let type:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown value type \(type)")
            }
            self = .value(prompt: prompt, field: field)
        case "disambiguation":
            self = .disambiguation(prompt: prompt, values: try container.decode([String].self, forKey: .values))
        case "valueConfirmation":
            self = .valueConfirmation(prompt: prompt, value: try container.decode(String.self, forKey: .value))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "unknown dialog \(kind)")
        }
    }

    static func rangeHint(min: Double?, max: Double?) -> String {
        switch (min, max) {
        case (let min?, let max?): String(localized: "Enter a number from \(min.formatted()) to \(max.formatted()).")
        case (let min?, nil): String(localized: "Enter a number of at least \(min.formatted()).")
        case (nil, let max?): String(localized: "Enter a number of at most \(max.formatted()).")
        case (nil, nil): ""
        }
    }

    var prompt: String? {
        switch self {
        case .choice(let prompt, _), .value(let prompt, _), .disambiguation(let prompt, _), .valueConfirmation(let prompt, _):
            prompt
        case .confirmation(let prompt, _):
            prompt
        }
    }
}

nonisolated enum DialogAnswer: Sendable {
    case none
    case index(Int)
    case confirmed(Bool)
    case text(String)
    case number(Double)
    case date(Date)
    case file(name: String, type: String, data: Data)
    case person(name: String, handle: (type: String, value: String)?)
    case placemark(name: String?, coordinate: CLLocationCoordinate2D?, address: String?)

    var json: String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
        return String(decoding: data, as: UTF8.self)
    }

    private var object: Any {
        switch self {
        case .none:
            return NSNull()
        case .index(let index):
            return index
        case .confirmed(let confirmed):
            return confirmed
        case .text(let text):
            return text
        case .number(let number):
            return number
        case .date(let date):
            return (date.timeIntervalSince1970 * 1000).rounded()
        case .file(let name, let type, let data):
            return ["name": name, "type": type, "data": data.base64EncodedString()]
        case .person(let name, let handle):
            var person: [String: Any] = ["name": name]
            person["handle"] = handle.map { ["type": $0.type, "value": $0.value] }
            return person
        case .placemark(let name, let coordinate, let address):
            var placemark: [String: Any] = [:]
            placemark["name"] = name
            placemark["coordinate"] = coordinate.map { [$0.latitude, $0.longitude] }
            placemark["address"] = address
            return placemark
        }
    }
}

typealias DialogPresenter = @MainActor @Sendable (DialogRequest) async throws -> DialogAnswer

enum DialogHost {
    case app
    case intent(DialogPresenter)
}
