import Foundation
import JavaScriptCore
import LibSwipt
import os

nonisolated final class Graphics: NSObject, LibSwiptGraphicsHandlerProtocol, @unchecked Sendable {
    static let shared = Graphics()
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Swipt", category: "graphics")

    private static let install: Int32 = 0
    private static let uninstall: Int32 = 1

    private typealias Native = @convention(c) (OpaquePointer?, Int32, OpaquePointer?, UInt64) -> Void

    nonisolated(unsafe) private static let native: Native = { context, command, value, engine in
        Graphics.shared.handle(context, command, value, engine)
    }

    private let work = DispatchQueue(label: "io.nekohasekai.swipt.graphics", qos: .userInitiated, attributes: .concurrent)
    private let engines = LockedState<[UInt64: GraphicsEngine]>(initialState: [:])

    func attach(_ device: LibSwiptDevice) {
        ScreenFeed.shared.attach(device)
        Recognition.warm()
    }

    func entry() -> Int64 {
        Int64(Int(bitPattern: unsafeBitCast(Graphics.native, to: UnsafeRawPointer.self)))
    }

    private func handle(_ context: OpaquePointer?, _ command: Int32, _ value: OpaquePointer?, _ id: UInt64) {
        switch command {
        case Graphics.install:
            guard let context, let wrapped = JSContext(jsGlobalContextRef: context), let target = JSValue(jsValueRef: value, in: wrapped) else { return }
            let engine = GraphicsEngine(id: id, context: wrapped)
            engines.withLock { $0[id] = engine }
            target.setValue(GraphicsNative(engine: engine), forProperty: "graphics")
        case Graphics.uninstall:
            engines.withLock { $0.removeValue(forKey: id) }?.close()
        default:
            break
        }
    }

    private func engine(_ id: Int64) -> GraphicsEngine? {
        engines.withLock { $0[UInt64(id)] }
    }

    func run(_ engine: Int64, call: Int64, context: LibSwiptGraphicsContext?) -> String {
        guard let context, let engine = self.engine(engine), let prepared = engine.takePrepared(Int(call)) else {
            return Outcome.failure(GraphicsError.ended)
        }
        let token = CancelToken { context.cancelled() }
        let outcome = LockedState<String?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        let box = UncheckedSendable(value: context)
        work.async {
            let result: String
            do {
                result = Outcome.success(try GraphicsCalls.execute(prepared, engine: engine, context: box.value, token: token))
            } catch {
                result = Outcome.failure(error)
            }
            outcome.withLock { $0 = result }
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if context.cancelled() {
                token.cancel()
                return Outcome.failure(GraphicsError.aborted)
            }
        }
        return outcome.withLock { $0 } ?? Outcome.failure(GraphicsError.aborted)
    }

    func watch(_ engine: Int64, call: Int64, context: LibSwiptGraphicsContext?, publisher: LibSwiptGraphicsPublisher?) -> String {
        guard let context, let publisher, let engine = self.engine(engine), let prepared = engine.takePrepared(Int(call)) else {
            return Outcome.failure(GraphicsError.ended)
        }
        let token = CancelToken { context.cancelled() }
        do {
            try GraphicsCalls.watch(prepared, engine: engine, token: token) { publisher.publish($0) }
            return Outcome.success(NSNull())
        } catch {
            return Outcome.failure(error)
        }
    }
}
