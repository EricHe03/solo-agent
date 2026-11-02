import CoreGraphics
import Foundation
import JavaScriptCore

nonisolated final class PreparedCall: @unchecked Sendable {
    let method: String
    let arguments: Arguments
    let objects: [Any]

    init(method: String, arguments: Arguments, objects: [Any]) {
        self.method = method
        self.arguments = arguments
        self.objects = objects
    }
}

nonisolated final class GraphicsEngine: @unchecked Sendable {
    let id: UInt64
    private var context: JSContext?
    private let lock = NSLock()
    private var next = 0
    private var prepared: [Int: PreparedCall] = [:]
    private var objects: [Int: Any] = [:]
    private var closed = false

    init(id: UInt64, context: JSContext) {
        self.id = id
        self.context = context
    }

    func prepare(_ call: PreparedCall) -> Int {
        lock.withLock {
            next += 1
            prepared[next] = call
            return next
        }
    }

    func takePrepared(_ id: Int) -> PreparedCall? {
        lock.withLock { prepared.removeValue(forKey: id) }
    }

    func register(_ object: Any) -> Int {
        let (id, accepted) = lock.withLock {
            next += 1
            if !closed {
                objects[next] = object
            }
            return (next, !closed)
        }
        if !accepted {
            (object as? RecordingSession)?.abandon()
        }
        return id
    }

    func take(_ id: Int) -> Any? {
        lock.withLock { objects.removeValue(forKey: id) }
    }

    func drop(_ id: Int) {
        _ = take(id)
    }

    func close() {
        let left: [Any] = lock.withLock {
            closed = true
            prepared.removeAll()
            let left = Array(objects.values)
            objects.removeAll()
            context = nil
            return left
        }
        for object in left {
            (object as? RecordingSession)?.abandon()
        }
    }
}

nonisolated enum JavaScript {
    private typealias ReportCost = @convention(c) (OpaquePointer?, Int) -> Void

    nonisolated(unsafe) private static let reportCost: ReportCost? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSReportExtraMemoryCost") else { return nil }
        return unsafeBitCast(symbol, to: ReportCost.self)
    }()

    static func report(_ bytes: Int) {
        guard bytes > 0, let context = JSContext.current() else { return }
        reportCost?(context.jsGlobalContextRef, bytes)
    }

    static func fail(_ error: any Error) -> JSValue {
        let context = JSContext.current()!
        let error = GraphicsError(error)
        let native = error.name == "TypeError" || error.name == "RangeError"
        let constructor = context.objectForKeyedSubscript(native ? error.name : "DOMException")
        context.exception = native ? constructor?.construct(withArguments: [error.message]) : constructor?.construct(withArguments: [error.message, error.name])
        return JSValue(undefinedIn: context)
    }

    static func bytes(_ data: Data) -> JSValue {
        let context = JSContext.current()!
        let count = data.count
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 16)
        data.copyBytes(to: storage.assumingMemoryBound(to: UInt8.self), count: count)
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(context.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, storage, count, { bytes, _ in
            bytes?.deallocate()
        }, nil, &exception)
        guard let array else {
            storage.deallocate()
            return fail(GraphicsError("Error", "graphics: make the byte array"))
        }
        return JSValue(jsValueRef: array, in: context)
    }

    static func data(_ value: JSValue) -> Data? {
        guard let context = value.context?.jsGlobalContextRef, let reference = value.jsValueRef,
              JSValueGetTypedArrayType(context, reference, nil) == kJSTypedArrayTypeUint8Array,
              let object = JSValueToObject(context, reference, nil)
        else { return nil }
        let length = JSObjectGetTypedArrayByteLength(context, object, nil)
        guard length > 0, let base = JSObjectGetTypedArrayBytesPtr(context, object, nil) else { return Data() }
        return Data(bytes: base + JSObjectGetTypedArrayByteOffset(context, object, nil), count: length)
    }
}

@objc protocol GraphicsNativeExports: JSExport {
    nonisolated func prepare(_ method: String, _ arguments: String, _ objects: JSValue) -> JSValue
    nonisolated func take(_ id: Int) -> JSValue
    nonisolated func bytes(_ id: Int) -> JSValue
}

@objc nonisolated final class GraphicsNative: NSObject, GraphicsNativeExports {
    private let engine: GraphicsEngine

    init(engine: GraphicsEngine) {
        self.engine = engine
    }

    func prepare(_ method: String, _ arguments: String, _ objects: JSValue) -> JSValue {
        let context = JSContext.current()!
        do {
            let parsed = try Arguments(json: arguments)
            var unwrapped: [Any] = []
            let count = Int(objects.forProperty("length")?.toInt32() ?? 0)
            for index in 0..<count {
                guard let item = objects.atIndex(index) else { continue }
                if let data = JavaScript.data(item) {
                    unwrapped.append(data)
                    continue
                }
                let object = item.toObject()
                if let handle = object as? ImageHandle {
                    unwrapped.append(handle.node)
                } else if let handle = object as? RecordingHandle {
                    unwrapped.append(handle.session)
                } else if let handle = object as? VideoHandle {
                    unwrapped.append(handle.model)
                } else {
                    throw GraphicsError.type("graphics: argument \(index + 1) of \(method) is not an Image, a Recording, a Video or a Uint8Array")
                }
            }
            return JSValue(double: Double(engine.prepare(PreparedCall(method: method, arguments: parsed, objects: unwrapped))), in: context)
        } catch {
            return JavaScript.fail(error)
        }
    }

    func take(_ id: Int) -> JSValue {
        let context = JSContext.current()!
        let object = engine.take(id)
        if let node = object as? ImageNode {
            JavaScript.report(node.estimatedBytes)
            return JSValue(object: ImageHandle(node), in: context)
        }
        if let session = object as? RecordingSession {
            return JSValue(object: RecordingHandle(session), in: context)
        }
        if let model = object as? VideoModel {
            return JSValue(object: VideoHandle(model), in: context)
        }
        if let text = object as? RecognizedText {
            return JSValue(object: TextHandle(text), in: context)
        }
        return JSValue(nullIn: context)
    }

    func bytes(_ id: Int) -> JSValue {
        guard let data = engine.take(id) as? Data else {
            return JSValue(nullIn: JSContext.current()!)
        }
        return JavaScript.bytes(data)
    }
}

@objc protocol ImageExports: JSExport {
    nonisolated var width: Double { get }
    nonisolated var height: Double { get }
    nonisolated var scale: Double { get }
    nonisolated var frame: [Double] { get }
    nonisolated var time: Double { get }
    nonisolated var timestamp: Double { get }
    nonisolated var pixelWidth: Int { get }
    nonisolated var pixelHeight: Int { get }
    nonisolated func crop(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> JSValue
    nonisolated func resize(_ width: Int, _ height: Int) -> ImageHandle
    nonisolated func rotate(_ degrees: Double) -> ImageHandle
    nonisolated func grayscale() -> ImageHandle
    nonisolated func threshold(_ level: Int) -> ImageHandle
    nonisolated func mask(_ lowRed: Int, _ lowGreen: Int, _ lowBlue: Int, _ highRed: Int, _ highGreen: Int, _ highBlue: Int) -> ImageHandle
    nonisolated func invert() -> ImageHandle
    nonisolated func dilate(_ radius: Int) -> ImageHandle
    nonisolated func erode(_ radius: Int) -> ImageHandle
    nonisolated func showBytes() -> JSValue
}

@objc nonisolated final class ImageHandle: NSObject, ImageExports {
    let node: ImageNode

    init(_ node: ImageNode) {
        self.node = node
    }

    private func derived(_ node: ImageNode) -> ImageHandle {
        JavaScript.report(node.estimatedBytes)
        return ImageHandle(node)
    }

    var width: Double { rounded(node.frame.width) }
    var height: Double { rounded(node.frame.height) }
    var scale: Double { rounded(node.scale) }
    var frame: [Double] { rectJSON(node.frame) }
    var time: Double { node.time ?? .nan }
    var timestamp: Double { node.timestamp ?? .nan }
    var pixelWidth: Int { node.pixelWidth }
    var pixelHeight: Int { node.pixelHeight }

    func crop(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> JSValue {
        do {
            return JSValue(object: ImageHandle(try node.crop(space: CGRect(x: x, y: y, width: width, height: height))), in: JSContext.current()!)
        } catch {
            return JavaScript.fail(error)
        }
    }

    func resize(_ width: Int, _ height: Int) -> ImageHandle {
        derived(node.resize(width: width, height: height))
    }

    func rotate(_ degrees: Double) -> ImageHandle {
        derived(node.rotate(degrees: degrees))
    }

    func grayscale() -> ImageHandle {
        derived(node.apply(.grayscale))
    }

    func threshold(_ level: Int) -> ImageHandle {
        derived(node.apply(.threshold(level: level)))
    }

    func mask(_ lowRed: Int, _ lowGreen: Int, _ lowBlue: Int, _ highRed: Int, _ highGreen: Int, _ highBlue: Int) -> ImageHandle {
        let clamp = { (value: Int) in UInt8(min(max(value, 0), 255)) }
        return derived(node.apply(.mask(low: [lowRed, lowGreen, lowBlue].map(clamp), high: [highRed, highGreen, highBlue].map(clamp))))
    }

    func invert() -> ImageHandle {
        derived(node.apply(.invert))
    }

    func dilate(_ radius: Int) -> ImageHandle {
        derived(node.apply(.dilate(radius: radius)))
    }

    func erode(_ radius: Int) -> ImageHandle {
        derived(node.apply(.erode(radius: radius)))
    }

    func showBytes() -> JSValue {
        do {
            return JavaScript.bytes(try node.raster().encode("png", quality: nil, scale: node.scale))
        } catch {
            return JavaScript.fail(error)
        }
    }
}

@objc protocol RecordingExports: JSExport {
    nonisolated var path: String { get }
    nonisolated var start: Double { get }
}

@objc nonisolated final class RecordingHandle: NSObject, RecordingExports {
    let session: RecordingSession

    init(_ session: RecordingSession) {
        self.session = session
    }

    var path: String { session.url.path }
    var start: Double { session.start }

    deinit {
        session.abandon()
    }
}

@objc protocol VideoExports: JSExport {
    nonisolated var info: String { get }
    nonisolated func frame(_ time: Double) -> ImageHandle
}

@objc nonisolated final class VideoHandle: NSObject, VideoExports {
    let model: VideoModel

    init(_ model: VideoModel) {
        self.model = model
    }

    var info: String { model.info() }

    func frame(_ time: Double) -> ImageHandle {
        let node = model.node(at: time)
        JavaScript.report(node.estimatedBytes)
        return ImageHandle(node)
    }
}

@objc protocol TextExports: JSExport {
    nonisolated func boundingBox(_ line: Int, _ candidate: Int, _ start: Int, _ end: Int) -> JSValue
}

@objc nonisolated final class TextHandle: NSObject, TextExports {
    private let text: RecognizedText

    init(_ text: RecognizedText) {
        self.text = text
    }

    func boundingBox(_ line: Int, _ candidate: Int, _ start: Int, _ end: Int) -> JSValue {
        let context = JSContext.current()!
        do {
            guard let box = try text.boundingBox(line: line, candidate: candidate, start: start, end: end) else {
                return JSValue(nullIn: context)
            }
            return JSValue(object: box, in: context)
        } catch {
            return JavaScript.fail(error)
        }
    }
}
