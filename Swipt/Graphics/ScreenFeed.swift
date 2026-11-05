import CoreMedia
import CoreVideo
import Foundation
import LibSwipt
import VideoToolbox
import os

nonisolated struct ScreenGeometry: Sendable {
    let width: Int
    let height: Int
    let scale: Double
}

nonisolated struct AccessUnit: @unchecked Sendable {
    var nals: [Data] = []
    var rtpTimestamp: UInt32 = 0
    var arrival: Double = 0
    var profile: UInt16 = 0
    var damaged = false

    static func type(_ nal: Data) -> Int {
        Int(nal[nal.startIndex] >> 1) & 0x3f
    }

    var isKeyframe: Bool {
        nals.contains { (16...23).contains(AccessUnit.type($0)) }
    }

    var hasParameterSets: Bool {
        nals.contains { AccessUnit.type($0) == 33 }
    }

    var turns: Int {
        guard profile & 0xf000 == 0x9000 else { return 0 }
        return [0, 2, 3, 1][Int(profile >> 8) & 3]
    }
}

nonisolated final class Depacketizer {
    private var current: AccessUnit?
    private var fragment: Data?
    private var lastSequence: UInt16?

    func reset() {
        current = nil
        fragment = nil
        lastSequence = nil
    }

    func push(_ packet: Data, arrival: Double) -> [AccessUnit] {
        var done: [AccessUnit] = []
        packet.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return }
            let marker = bytes[1] & 0x80 != 0
            let sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
            var offset = 12 + 4 * Int(bytes[0] & 0x0f)
            var profile: UInt16 = 0
            if bytes[0] & 0x10 != 0 {
                guard bytes.count >= offset + 4 else { return }
                profile = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
                offset += 4 + 4 * Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            }
            var end = bytes.count
            if bytes[0] & 0x20 != 0 {
                end -= Int(bytes[end - 1])
            }
            guard offset + 2 <= end else { return }
            var gap = false
            if let lastSequence, sequence != lastSequence &+ 1 {
                gap = true
            }
            lastSequence = sequence
            if var unit = current, unit.rtpTimestamp != timestamp {
                if fragment != nil {
                    unit.damaged = true
                    fragment = nil
                }
                done.append(unit)
                current = nil
            }
            var unit = current ?? AccessUnit(rtpTimestamp: timestamp, arrival: arrival, profile: profile)
            if gap {
                unit.damaged = true
                fragment = nil
            }
            let payload = Data(bytes: bytes.baseAddress! + offset, count: end - offset)
            switch Int(payload[0] >> 1) & 0x3f {
            case 48:
                var at = 2
                while at + 2 <= payload.count {
                    let size = Int(payload[at]) << 8 | Int(payload[at + 1])
                    at += 2
                    guard size > 0, at + size <= payload.count else {
                        unit.damaged = true
                        break
                    }
                    unit.nals.append(payload.subdata(in: at..<at + size))
                    at += size
                }
            case 49:
                guard payload.count > 3 else {
                    unit.damaged = true
                    break
                }
                let header = payload[2]
                if header & 0x80 != 0 {
                    var nal = Data([payload[0] & 0x81 | (header & 0x3f) << 1, payload[1]])
                    nal.append(payload.subdata(in: 3..<payload.count))
                    fragment = nal
                } else if fragment != nil {
                    fragment!.append(payload.subdata(in: 3..<payload.count))
                } else {
                    unit.damaged = true
                }
                if header & 0x40 != 0, let nal = fragment {
                    unit.nals.append(nal)
                    fragment = nil
                }
            default:
                unit.nals.append(payload)
            }
            if marker {
                done.append(unit)
                current = nil
                fragment = nil
            } else {
                current = unit
            }
        }
        return done
    }
}

nonisolated enum HEVC {
    static func format(_ nals: [Data]) -> CMVideoFormatDescription? {
        func first(_ type: Int) -> Data? { nals.first { AccessUnit.type($0) == type } }
        guard let vps = first(32), let sps = first(33), let pps = first(34) else { return nil }
        let sets = [vps, sps, pps]
        var description: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBytes { a in
            sets[1].withUnsafeBytes { b in
                sets[2].withUnsafeBytes { c in
                    let pointers = [a, b, c].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: nil, parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
                }
            }
        }
        return status == noErr ? description : nil
    }

    static func sample(_ unit: AccessUnit, format: CMVideoFormatDescription, time: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        var payload = Data()
        for nal in unit.nals where !(32...34).contains(AccessUnit.type(nal)) {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(nal)
        }
        guard !payload.isEmpty else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block
        else { return nil }
        let copied = payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        if !unit.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments[0][kCMSampleAttachmentKey_NotSync] = true
            attachments[0][kCMSampleAttachmentKey_DependsOnOthers] = true
        }
        return sample
    }
}

nonisolated final class RTPClock {
    private var last: UInt32?
    private var high: Int64 = 0
    private var base: Int64?

    func time(_ timestamp: UInt32) -> CMTime {
        if let last, timestamp < last, last - timestamp > 0x8000_0000 {
            high += 1 << 32
        }
        last = timestamp
        let value = high + Int64(timestamp)
        if base == nil {
            base = value
        }
        return CMTime(value: value - base!, timescale: 24000)
    }
}

nonisolated final class FrameDecoder: @unchecked Sendable {
    var onFrame: ((CVPixelBuffer, AccessUnit) -> Void)?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var waitingForKeyframe = true
    private let failed = LockedState(initialState: false)
    private let clock = RTPClock()

    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        waitingForKeyframe = true
    }

    private func makeSession(_ format: CMVideoFormatDescription) -> Bool {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &created)
        guard status == noErr, let created else {
            Graphics.logger.error("create the screen decoder: OSStatus \(status, privacy: .public)")
            return false
        }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return true
    }

    func decode(_ unit: AccessUnit) -> Bool {
        if failed.withLock({ value in defer { value = false }; return value }) {
            invalidate()
        }
        if unit.damaged {
            waitingForKeyframe = true
            return true
        }
        if unit.hasParameterSets, let described = HEVC.format(unit.nals) {
            if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: described) || session == nil {
                format = described
                if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: described) {
                } else if !makeSession(described) {
                    return true
                }
            }
        }
        if waitingForKeyframe {
            guard unit.isKeyframe else { return true }
            waitingForKeyframe = false
        }
        if session == nil, let format, !makeSession(format) {
            return true
        }
        guard let session, let format, let sample = HEVC.sample(unit, format: format, time: clock.time(unit.rtpTimestamp)) else { return false }
        var info = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._1xRealTimePlayback, ._EnableAsynchronousDecompression], infoFlagsOut: &info) {
            [weak self] status, _, image, _, _ in
            guard let self else { return }
            guard status == noErr, let image else {
                self.failed.withLock { $0 = true }
                return
            }
            self.onFrame?(image, unit)
        }
        if status != noErr {
            invalidate()
            return true
        }
        return false
    }
}

nonisolated final class Frame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: Double
    let turns: Int
    let geometry: ScreenGeometry
    let cropWidth: Int
    let cropHeight: Int
    private let quarterLock = NSLock()
    private var quarterPlane: Raster?

    init(pixelBuffer: CVPixelBuffer, time: Double, turns: Int, geometry: ScreenGeometry) {
        self.pixelBuffer = pixelBuffer
        self.time = time
        self.turns = turns
        self.geometry = geometry
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        cropWidth = geometry.width > 0 ? min(geometry.width, width) : width
        cropHeight = geometry.height > 0 ? min(geometry.height, height) : height
    }

    var pixelWidth: Int { turns % 2 == 0 ? cropWidth : cropHeight }
    var pixelHeight: Int { turns % 2 == 0 ? cropHeight : cropWidth }

    private func native() throws -> Raster {
        let storage = try RasterStorage(pixelBuffer: pixelBuffer)
        return Raster(storage: storage, data: storage.base, width: cropWidth, height: cropHeight, rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer), channels: 4)
    }

    func raster() throws -> Raster {
        try native().rotated(quarterTurns: turns)
    }

    func quarter() throws -> Raster {
        try quarterLock.withLock {
            if let quarterPlane {
                return quarterPlane
            }
            let made = try Frame.quartered(pixelBuffer, width: max(cropWidth / 4, 1), height: max(cropHeight / 4, 1)).grayscale().rotated(quarterTurns: turns)
            quarterPlane = made
            return made
        }
    }

    private static let scaling = LockedState<VTPixelTransferSession?>(initialState: nil)

    private static func quartered(_ source: CVPixelBuffer, width: Int, height: Int) throws -> Raster {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, max(CVPixelBufferGetWidth(source) / 4, width), max(CVPixelBufferGetHeight(source) / 4, height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess, let made else {
            throw GraphicsError("Error", "graphics: allocate the scaled frame")
        }
        let status = scaling.withLock { session -> OSStatus in
            if session == nil {
                var created: VTPixelTransferSession?
                guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr else { return -1 }
                session = created
            }
            return VTPixelTransferSessionTransferImage(session!, from: source, to: made)
        }
        guard status == noErr else {
            throw GraphicsError("Error", "graphics: scale the frame (\(status))")
        }
        let storage = try RasterStorage(pixelBuffer: made)
        return Raster(storage: storage, data: storage.base, width: width, height: height, rowBytes: CVPixelBufferGetBytesPerRow(made), channels: 4)
    }
}

nonisolated final class ScreenFeed: NSObject, LibSwiptScreenSinkProtocol, @unchecked Sendable {
    static let shared = ScreenFeed()
    static let linger: Double = 1
    static let firstFrameLimit: Double = 5

    private let queue = DispatchQueue(label: "io.nekohasekai.swipt.graphics.screen", qos: .userInteractive)
    private let state = NSCondition()
    private var device: LibSwiptDevice?
    private var feed: LibSwiptScreenFeed?
    private var geometry: ScreenGeometry?
    private var users = 0
    private var opening = false
    private var lingering: DispatchWorkItem?
    private var latest: Frame?
    private var sequence = 0
    private var failure: GraphicsError?
    private var frameListeners: [Int: (Frame) -> Void] = [:]
    private var unitListeners: [Int: (AccessUnit) -> Void] = [:]
    private var nextListener = 0

    private let depacketizer = Depacketizer()
    private let decoder = FrameDecoder()

    override init() {
        super.init()
        decoder.onFrame = { [weak self] image, unit in
            self?.decoded(image, unit)
        }
    }

    func attach(_ device: LibSwiptDevice) {
        state.withLock { self.device = device }
    }

    func acquire() throws -> ScreenGeometry {
        state.lock()
        defer { state.unlock() }
        users += 1
        lingering?.cancel()
        lingering = nil
        while opening {
            state.wait()
        }
        if let geometry, feed != nil {
            return geometry
        }
        guard let device else {
            users -= 1
            throw GraphicsError.unavailable("graphics: there is no device")
        }
        opening = true
        queue.async { [self] in
            depacketizer.reset()
            decoder.invalidate()
        }
        state.unlock()
        let opened = Result { try device.openScreen(self) }
        state.lock()
        opening = false
        state.broadcast()
        switch opened {
        case .success(let feed):
            let info = (try? JSONSerialization.jsonObject(with: Data(feed.info().utf8))) as? [String: Any] ?? [:]
            let geometry = ScreenGeometry(
                width: (info["width"] as? NSNumber)?.intValue ?? 0, height: (info["height"] as? NSNumber)?.intValue ?? 0,
                scale: max((info["scale"] as? NSNumber)?.doubleValue ?? 1, 1))
            self.feed = feed
            self.geometry = geometry
            failure = nil
            latest = nil
            return geometry
        case .failure(let error):
            users -= 1
            throw GraphicsError(failure: error.localizedDescription)
        }
    }

    func release() {
        state.withLock {
            users -= 1
            guard users == 0 else { return }
            let work = DispatchWorkItem { [weak self] in self?.closeIfIdle() }
            lingering = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + ScreenFeed.linger, execute: work)
        }
    }

    private func closeIfIdle() {
        let closing: LibSwiptScreenFeed? = state.withLock {
            guard users == 0, let feed else { return nil }
            self.feed = nil
            geometry = nil
            latest = nil
            return feed
        }
        closing?.close()
    }

    func requestKeyFrame() {
        let feed = state.withLock { self.feed }
        feed?.requestKeyFrame()
    }

    func latestFrame() -> (Frame, Int)? {
        state.withLock { latest.map { ($0, sequence) } }
    }

    func frame(after previous: Int, until deadline: Date, token: CancelToken) throws -> (Frame, Int)? {
        state.lock()
        defer { state.unlock() }
        while true {
            if let failure {
                throw failure
            }
            if feed == nil, !opening {
                throw GraphicsError.unavailable("graphics: the screen stream stopped")
            }
            if let latest, sequence > previous {
                return (latest, sequence)
            }
            if token.isCancelled {
                throw GraphicsError.aborted
            }
            let now = Date()
            if now >= deadline {
                return nil
            }
            _ = state.wait(until: min(deadline, now.addingTimeInterval(0.05)))
        }
    }

    func addFrameListener(_ listener: @escaping (Frame) -> Void) -> Int {
        state.withLock {
            nextListener += 1
            frameListeners[nextListener] = listener
            return nextListener
        }
    }

    func addUnitListener(_ listener: @escaping (AccessUnit) -> Void) -> Int {
        state.withLock {
            nextListener += 1
            unitListeners[nextListener] = listener
            return nextListener
        }
    }

    func removeListener(_ id: Int) {
        state.withLock {
            frameListeners.removeValue(forKey: id)
            unitListeners.removeValue(forKey: id)
        }
    }

    func onPackets(_ batch: Data?) {
        guard let batch else { return }
        queue.async { [self] in
            process(batch)
        }
    }

    func onEnd(_ failure: String?) {
        state.withLock {
            self.failure = GraphicsError(failure: failure ?? "")
            feed = nil
            geometry = nil
            latest = nil
            state.broadcast()
        }
    }

    private func process(_ batch: Data) {
        let listeners = state.withLock { Array(unitListeners.values) }
        var units: [AccessUnit] = []
        batch.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset + 13 <= bytes.count {
                var arrival: UInt64 = 0
                var length: UInt32 = 0
                for index in 0..<8 {
                    arrival = arrival << 8 | UInt64(bytes[offset + index])
                }
                let rtcp = bytes[offset + 8] != 0
                for index in 9..<13 {
                    length = length << 8 | UInt32(bytes[offset + index])
                }
                offset += 13
                guard offset + Int(length) <= bytes.count else { break }
                if !rtcp {
                    let packet = Data(bytes: bytes.baseAddress! + offset, count: Int(length))
                    units += depacketizer.push(packet, arrival: Double(arrival) / 1e6)
                }
                offset += Int(length)
            }
        }
        for unit in units {
            for listener in listeners {
                listener(unit)
            }
            if decoder.decode(unit) {
                requestKeyFrame()
            }
        }
    }

    private func decoded(_ image: CVPixelBuffer, _ unit: AccessUnit) {
        let delivery: (Frame, [(Frame) -> Void])? = state.withLock {
            guard let geometry, feed != nil else { return nil }
            let frame = Frame(pixelBuffer: image, time: unit.arrival, turns: unit.turns, geometry: geometry)
            latest = frame
            sequence += 1
            state.broadcast()
            return (frame, Array(frameListeners.values))
        }
        guard let delivery else { return }
        for listener in delivery.1 {
            listener(delivery.0)
        }
    }
}
