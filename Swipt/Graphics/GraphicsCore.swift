import CoreGraphics
import Foundation

nonisolated struct GraphicsError: Error, Sendable {
    let name: String
    let message: String

    init(_ name: String, _ message: String) {
        self.name = name
        self.message = message
    }

    init(_ error: any Error) {
        if let error = error as? GraphicsError {
            self = error
        } else {
            self.init("Error", error.localizedDescription)
        }
    }

    init(failure: String) {
        let decoded = (try? JSONSerialization.jsonObject(with: Data(failure.utf8))) as? [String: Any]
        self.init(decoded?["name"] as? String ?? "Error", decoded?["message"] as? String ?? failure)
    }

    static func type(_ message: String) -> GraphicsError { GraphicsError("TypeError", message) }
    static func range(_ message: String) -> GraphicsError { GraphicsError("RangeError", message) }
    static func data(_ message: String) -> GraphicsError { GraphicsError("DataError", message) }
    static func timeout(_ message: String) -> GraphicsError { GraphicsError("TimeoutError", message) }
    static func unavailable(_ message: String) -> GraphicsError { GraphicsError("UnavailableError", message) }
    static func state(_ message: String) -> GraphicsError { GraphicsError("InvalidStateError", message) }
    static let aborted = GraphicsError("AbortError", "the operation was aborted")
    static let ended = GraphicsError("AbortError", "the JavaScript session ended")
    static let released = GraphicsError("InvalidStateError", "the image was released")
}

nonisolated enum Outcome {
    static func success(_ value: Any) -> String {
        encode(["value": value]) ?? failure(GraphicsError("Error", "graphics: the result does not pass through JSON"))
    }

    static func failure(_ error: any Error) -> String {
        let error = GraphicsError(error)
        return encode(["error": ["name": error.name, "message": error.message]]) ?? #"{"error":{"name":"Error","message":"graphics: the error does not pass through JSON"}}"#
    }

    static func encode(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated struct Arguments: @unchecked Sendable {
    let values: [String: Any]

    init(json: String) throws {
        guard let values = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw GraphicsError.type("graphics: the arguments are not a JSON object")
        }
        self.values = values
    }

    init(values: [String: Any]) {
        self.values = values
    }

    func double(_ key: String) -> Double? {
        (values[key] as? NSNumber).map(\.doubleValue)
    }

    func int(_ key: String) -> Int? {
        (values[key] as? NSNumber).map(\.intValue)
    }

    func bool(_ key: String) -> Bool? {
        (values[key] as? NSNumber).map(\.boolValue)
    }

    func string(_ key: String) -> String? {
        values[key] as? String
    }

    func strings(_ key: String) -> [String]? {
        values[key] as? [String]
    }

    func doubles(_ key: String) -> [Double]? {
        (values[key] as? [NSNumber]).map { $0.map(\.doubleValue) }
    }

    func rect(_ key: String) -> CGRect? {
        guard let numbers = doubles(key), numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    func point(_ key: String) -> CGPoint? {
        guard let numbers = doubles(key), numbers.count == 2 else { return nil }
        return CGPoint(x: numbers[0], y: numbers[1])
    }

    func objects(_ key: String) -> [[String: Any]] {
        values[key] as? [[String: Any]] ?? []
    }

    func timeout(_ key: String = "timeoutMs") -> Double {
        guard let value = values[key], !(value is NSNull) else { return .infinity }
        return (value as? NSNumber)?.doubleValue ?? .infinity
    }
}

nonisolated func rounded(_ value: Double) -> Double {
    value.isFinite ? (value * 100).rounded() / 100 : 0
}

nonisolated func pointJSON(_ point: CGPoint) -> [Double] {
    [rounded(point.x), rounded(point.y)]
}

nonisolated func rectJSON(_ rect: CGRect) -> [Double] {
    [rounded(rect.minX), rounded(rect.minY), rounded(rect.width), rounded(rect.height)]
}

nonisolated func centerJSON(_ rect: CGRect) -> [Double] {
    pointJSON(CGPoint(x: rect.midX, y: rect.midY))
}

nonisolated func nowMilliseconds() -> Double {
    Date().timeIntervalSince1970 * 1000
}

nonisolated final class CancelToken: @unchecked Sendable {
    private let context: (() -> Bool)?
    private let flag = LockedState(initialState: false)

    init(_ cancelled: (() -> Bool)?) {
        context = cancelled
    }

    var isCancelled: Bool {
        flag.withLock { $0 } || context?() == true
    }

    func cancel() {
        flag.withLock { $0 = true }
    }

    func check() throws {
        if isCancelled {
            throw GraphicsError.aborted
        }
    }
}

nonisolated func awaitTask<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let result = LockedState<Result<T, any Error>?>(initialState: nil)
    Task.detached {
        do {
            let value = try await operation()
            result.withLock { $0 = .success(value) }
        } catch {
            result.withLock { $0 = .failure(error) }
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.withLock { $0! }.get()
}
