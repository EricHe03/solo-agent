import AVFoundation
import Accelerate
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class SegmentReader: @unchecked Sendable {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var current: (time: Double, buffer: CVPixelBuffer)?
    private var pending: (time: Double, buffer: CVPixelBuffer)?

    init(url: URL) throws {
        let asset = AVURLAsset(url: url)
        let box = UncheckedSendable(value: asset)
        let tracks = try awaitTask { UncheckedSendable(value: try await box.value.loadTracks(withMediaType: .video)) }.value
        guard let track = tracks.first else {
            throw GraphicsError.data("graphics: \(url.lastPathComponent) has no video track")
        }
        self.asset = asset
        self.track = track
    }

    private func restart(at seconds: Double) throws {
        reader?.cancelReading()
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(seconds - 1, 0), preferredTimescale: 600), duration: .positiveInfinity)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw GraphicsError("Error", "graphics: read the video")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw GraphicsError("Error", "graphics: read the video: \(reader.error?.localizedDescription ?? "unknown")")
        }
        self.reader = reader
        self.output = output
        current = nil
        pending = nil
    }

    private func next() -> (time: Double, buffer: CVPixelBuffer)? {
        while let sample = output?.copyNextSampleBuffer() {
            if let image = CMSampleBufferGetImageBuffer(sample) {
                return (CMSampleBufferGetPresentationTimeStamp(sample).seconds, image)
            }
        }
        return nil
    }

    func frame(at seconds: Double) throws -> CVPixelBuffer {
        try lock.withLock {
            let reusable = current.map { $0.time <= seconds && seconds - $0.time < 2 } ?? false
            if !reusable {
                try restart(at: seconds)
            }
            if let pending, pending.time <= seconds {
                current = pending
                self.pending = nil
            }
            while pending == nil, let sample = next() {
                if sample.time <= seconds + 0.0005 {
                    current = sample
                } else {
                    pending = sample
                }
            }
            if let current {
                return current.buffer
            }
            if let pending {
                return pending.buffer
            }
            throw GraphicsError.data("graphics: the video has no frame at \(Int(seconds * 1000)) ms")
        }
    }
}

nonisolated final class VideoModel: @unchecked Sendable {
    struct Segment {
        let url: URL
        let start: Double
        let duration: Double
        let turns: Int
    }

    let url: URL
    let start: Double?
    let duration: Double
    let scale: Double
    let clockOffset: Double
    let screen: ScreenGeometry
    let segments: [Segment]
    let changes: [[String: Any]]
    let events: [[String: Any]]

    private let lock = NSLock()
    private var readers: [Int: SegmentReader] = [:]

    init(url: URL, metadata: [String: Any]) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        start = (metadata["start"] as? NSNumber)?.doubleValue
        duration = (metadata["duration"] as? NSNumber)?.doubleValue ?? 0
        scale = (metadata["scale"] as? NSNumber)?.doubleValue ?? 1
        clockOffset = (metadata["clockOffset"] as? NSNumber)?.doubleValue ?? 0
        let screen = metadata["screen"] as? [String: Any] ?? [:]
        self.screen = ScreenGeometry(width: (screen["width"] as? NSNumber)?.intValue ?? 0, height: (screen["height"] as? NSNumber)?.intValue ?? 0, scale: scale)
        segments = (metadata["segments"] as? [[String: Any]] ?? []).compactMap { segment in
            guard let file = segment["file"] as? String else { return nil }
            return Segment(
                url: directory.appendingPathComponent(file), start: (segment["start"] as? NSNumber)?.doubleValue ?? 0,
                duration: (segment["duration"] as? NSNumber)?.doubleValue ?? 0, turns: (segment["turns"] as? NSNumber)?.intValue ?? 0)
        }
        guard !segments.isEmpty else {
            throw GraphicsError.data("graphics: the recording lists no video")
        }
        changes = metadata["changes"] as? [[String: Any]] ?? []
        events = metadata["events"] as? [[String: Any]] ?? []
    }

    static func sidecar(of url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("json")
    }

    static func open(_ url: URL, token: CancelToken) throws -> VideoModel {
        if let data = try? Data(contentsOf: sidecar(of: url)), let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return try VideoModel(url: url, metadata: metadata)
        }
        return try analyze(url, token: token)
    }

    private static func analyze(_ url: URL, token: CancelToken) throws -> VideoModel {
        let asset = AVURLAsset(url: url)
        let box = UncheckedSendable(value: asset)
        let loaded = try awaitTask { () -> UncheckedSendable<([AVAssetTrack], CMTime)> in
            let tracks = try await box.value.loadTracks(withMediaType: .video)
            let duration = try await box.value.load(.duration)
            return UncheckedSendable(value: (tracks, duration))
        }.value
        guard let track = loaded.0.first else {
            throw GraphicsError.data("graphics: \(url.lastPathComponent) has no video track")
        }
        let trackBox = UncheckedSendable(value: track)
        let shape = try awaitTask { UncheckedSendable(value: try await trackBox.value.load(.naturalSize, .preferredTransform)) }.value
        let size = shape.0
        let transform = shape.1
        let turns = (Int((atan2(Double(transform.b), Double(transform.a)) / (.pi / 2)).rounded()) % 4 + 4) % 4
        let width = Int(size.width)
        let height = Int(size.height)
        let factor = 4
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(width / factor, 1), kCVPixelBufferHeightKey as String: max(height / factor, 1),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw GraphicsError.data("graphics: read \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")")
        }
        let tracker = ChangeTracker()
        var lastTime = 0.0
        while let sample = output.copyNextSampleBuffer() {
            try token.check()
            guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
            let storage = try RasterStorage(pixelBuffer: image)
            let raster = Raster(storage: storage, data: storage.base, width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image),
                                rowBytes: CVPixelBufferGetBytesPerRow(image), channels: 4)
            try tracker.push(raster.grayscale().rotated(quarterTurns: turns), time: time)
            lastTime = time
        }
        try tracker.finish()
        let duration = max(loaded.1.seconds * 1000, lastTime)
        let upright = turns % 2 == 0 ? (width, height) : (height, width)
        let metadata: [String: Any] = [
            "duration": duration, "scale": 1, "screen": ["width": width, "height": height],
            "segments": [["file": url.lastPathComponent, "start": 0, "duration": duration, "turns": turns]],
            "changes": tracker.changes.map { change in
                VideoModel.change(change, factor: Double(upright.0) / Double(max(change.width, 1)), scale: 1, app: nil)
            },
        ]
        return try VideoModel(url: url, metadata: metadata)
    }

    static func change(_ change: ChangeTracker.Change, factor: Double, scale: Double, app: String?) -> [String: Any] {
        [
            "time": rounded(change.start), "end": rounded(change.after), "before": rounded(change.before), "after": rounded(change.after),
            "frames": change.regions.map { region in
                rectJSON(CGRect(x: region.minX * factor / scale, y: region.minY * factor / scale, width: region.width * factor / scale, height: region.height * factor / scale))
            },
            "app": app.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func stored(_ time: Double) -> Double {
        time - clockOffset
    }

    private func segmentIndex(at time: Double) -> Int {
        segments.lastIndex { $0.start <= time } ?? 0
    }

    func pixelSize(at time: Double) -> (width: Int, height: Int) {
        let segment = segments[segmentIndex(at: stored(time))]
        let width = screen.width
        let height = screen.height
        return segment.turns % 2 == 0 ? (width, height) : (height, width)
    }

    var pointSize: (width: Double, height: Double) {
        let size = pixelSize(at: 0)
        return (Double(size.width) / scale, Double(size.height) / scale)
    }

    func raster(at time: Double, token: CancelToken?) throws -> Raster {
        let stored = stored(time)
        let index = segmentIndex(at: stored)
        let segment = segments[index]
        let reader = try lock.withLock {
            if let reader = readers[index] {
                return reader
            }
            let reader = try SegmentReader(url: segment.url)
            readers[index] = reader
            return reader
        }
        try token?.check()
        let buffer = try reader.frame(at: max(stored - segment.start, 0) / 1000)
        return try Frame(pixelBuffer: buffer, time: time, turns: segment.turns, geometry: screen).raster()
    }

    func info() -> String {
        let size = pointSize
        let object: [String: Any] = [
            "path": url.path, "start": start.map { $0 as Any } ?? NSNull(), "duration": rounded(duration), "width": rounded(size.width), "height": rounded(size.height),
            "scale": scale, "changes": changes, "events": events,
        ]
        return Outcome.encode(object) ?? "{}"
    }

    func node(at time: Double) -> ImageNode {
        ImageNode.video(self, time: min(max(time, 0), duration))
    }

    func grid(times: [Double], columns: Int, width cellWidth: Int, token: CancelToken) throws -> Raster {
        let sorted = times.sorted()
        var cells: [(time: Double, raster: Raster)] = []
        for time in sorted {
            try token.check()
            cells.append((time, try raster(at: time, token: token)))
        }
        guard let first = cells.first?.raster else {
            throw GraphicsError.range("graphics: the grid has no frames")
        }
        let cellHeight = max(Int((Double(first.height) * Double(cellWidth) / Double(first.width)).rounded()), 1)
        let label = 30
        let gap = 4
        let columns = min(columns, cells.count)
        let rows = (cells.count + columns - 1) / columns
        let canvas = Raster(width: columns * cellWidth + (columns + 1) * gap, height: rows * (cellHeight + label + gap) + gap, channels: 4)
        var buffer = canvas.buffer
        let background: [UInt8] = [24, 24, 24, 255]
        try require(vImageBufferFill_ARGB8888(&buffer, background, vImage_Flags(kvImageNoFlags)), "fill the grid")
        let origins = cells.indices.map { index in
            (x: gap + index % columns * (cellWidth + gap), y: gap + index / columns * (cellHeight + label + gap))
        }
        for (index, cell) in cells.enumerated() {
            let height = max(Int((Double(cell.raster.height) * Double(cellWidth) / Double(cell.raster.width)).rounded()), 1)
            try cell.raster.resized(width: cellWidth, height: min(height, cellHeight)).copied(into: canvas, x: origins[index].x, y: origins[index].y + label)
        }
        guard let context = CGContext(
            data: canvas.data, width: canvas.width, height: canvas.height, bitsPerComponent: 8, bytesPerRow: canvas.rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else {
            throw GraphicsError("Error", "graphics: create the drawing context")
        }
        let font = CTFontCreateUIFontForLanguage(.system, 20, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        for (index, cell) in cells.enumerated() {
            let milliseconds = Int(cell.time.rounded())
            let text = String(format: "%d:%02d.%03d", milliseconds / 60000, milliseconds / 1000 % 60, milliseconds % 1000)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: origins[index].x + 6, y: canvas.height - origins[index].y - label + 8)
            CTLineDraw(line, context)
        }
        return canvas
    }

    func defaultGridTimes() -> [Double] {
        let changed = [0] + changes.compactMap { ($0["after"] as? NSNumber)?.doubleValue }
        if changed.count > 1 {
            let step = max(Double(changed.count) / 16, 1)
            return stride(from: 0.0, to: Double(changed.count), by: step).map { changed[Int($0)] }
        }
        let count = 12.0
        return stride(from: 0.0, to: count, by: 1).map { duration * $0 / count }
    }

    func export(_ arguments: Arguments, token: CancelToken) throws -> String {
        let path = arguments.string("path") ?? url.deletingPathExtension().path + "-export.mp4"
        let target = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        let format = arguments.string("format") ?? "mp4"
        let from = arguments.double("from") ?? 0
        let to = arguments.double("to") ?? duration
        let rate = arguments.double("frameRate") ?? (format == "gif" ? 10 : 30)
        let factor = arguments.double("scale") ?? 1
        let region = arguments.rect("region")
        let step = 1000 / rate
        let times = Array(stride(from: from, through: to, by: step))
        guard !times.isEmpty else {
            throw GraphicsError.range("graphics: the range has no frames")
        }
        let frame = { (time: Double) throws -> Raster in
            let node = self.node(at: time)
            let source = try region.map { try node.crop(space: $0) } ?? node
            let raster = try source.raster(token)
            let width = max(Int((Double(raster.width) * factor).rounded()), 2)
            let height = max(Int((Double(raster.height) * factor).rounded()), 2)
            return try raster.resized(width: format == "gif" ? width : width & ~1, height: format == "gif" ? height : height & ~1)
        }
        if format == "gif" {
            guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
                throw GraphicsError("Error", "graphics: create the GIF")
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for time in times {
                try token.check()
                CGImageDestinationAddImage(destination, try frame(time).cgImage(), [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: step / 1000]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else {
                throw GraphicsError("Error", "graphics: write the GIF")
            }
            return target.path
        }
        let first = try frame(times[0])
        let writer = try AVAssetWriter(outputURL: target, fileType: format == "mov" ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: format == "mov" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: first.width, AVVideoHeightKey: first.height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: first.width, kCVPixelBufferHeightKey as String: first.height,
        ])
        guard writer.canAdd(input) else {
            throw GraphicsError("Error", "graphics: create the video writer")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw GraphicsError("Error", "graphics: start the video: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times.enumerated() {
            try token.check()
            let raster = try index == 0 ? first : frame(time)
            while !input.isReadyForMoreMediaData {
                try token.check()
                usleep(2000)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw GraphicsError("Error", "graphics: the video writer has no buffers: \(writer.error?.localizedDescription ?? "unknown")")
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else {
                throw GraphicsError("Error", "graphics: allocate a video frame")
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
                for row in 0..<min(raster.height, CVPixelBufferGetHeight(buffer)) {
                    memcpy(base + row * rowBytes, raster.row(row), min(raster.width, CVPixelBufferGetWidth(buffer)) * 4)
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64((time - from).rounded()), timescale: 1000)) else {
                throw GraphicsError("Error", "graphics: write the video: \(writer.error?.localizedDescription ?? "unknown")")
            }
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw GraphicsError("Error", "graphics: finish the video: \(writer.error?.localizedDescription ?? "unknown")")
        }
        return target.path
    }
}
