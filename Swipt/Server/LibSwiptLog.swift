import Foundation
import LibSwipt
import os

nonisolated final class LibSwiptLog: NSObject, LibSwiptLogHandlerProtocol {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "libswipt")

    static let installed: Void = LibSwiptSetLogHandler(LibSwiptLog(), LibSwiptLogLevelDebug)

    func log(_ level: Int32, message: String?) {
        let text = message ?? ""
        switch level {
        case ...LibSwiptLogLevelError: Self.logger.error("\(text, privacy: .public)")
        case LibSwiptLogLevelWarn: Self.logger.warning("\(text, privacy: .public)")
        case LibSwiptLogLevelInfo: Self.logger.info("\(text, privacy: .public)")
        default: Self.logger.debug("\(text, privacy: .public)")
        }
    }
}
