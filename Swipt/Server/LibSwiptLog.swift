import Foundation
import LibSwipt
import os

nonisolated final class LibSwiptLog: NSObject, LibSwiptLogHandlerProtocol {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "libswipt")

    static let installed: Void = LibSwiptSetLogHandler(LibSwiptLog(), -4)

    func log(_ level: Int32, message: String?) {
        let text = message ?? ""
        switch level {
        case ..<0: Self.logger.debug("\(text, privacy: .public)")
        case ..<4: Self.logger.info("\(text, privacy: .public)")
        case ..<8: Self.logger.warning("\(text, privacy: .public)")
        default: Self.logger.error("\(text, privacy: .public)")
        }
    }
}
