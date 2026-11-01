import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LibSwipt
import os

nonisolated final class SegmentWriter: @unchecked Sendable {
    let url: URL
    let format: CMVideoFormatDescription
    let turns: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let clock = RTPClock()
    private var pending: (unit: AccessUnit, time: CMTime)?
    private(set) var end = CMTime.zero
    private(set) var failure: String?

    init(url: URL, format: CMVideoFormatDescription, turns: Int) throws {
        self.url = url
        self.format = format
        self.turns = turns
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        input.transform = CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2)
        guard writer.canAdd(input) else {
            throw GraphicsError("Error", "graphics: add the video track")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw GraphicsError("Error", "graphics: start writing: \(writer.error?.localizedDescription ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ unit: AccessUnit) -> CMTime {
        let time = clock.time(unit.rtpTimestamp)
        if let pending {
            write(pending.unit, time: pending.time, duration: CMTimeSubtract(time, pending.time))
        }
        pending = (unit, time)
        return time
    }

    private func write(_ unit: AccessUnit, time: CMTime, duration: CMTime) {
        guard let sample = HEVC.sample(unit, format: format, time: time, duration: duration), input.isReadyForMoreMediaData else { return }
        if input.append(sample) {
            end = CMTimeAdd(time, duration)
        } else if failure == nil {
            failure = writer.error?.localizedDescription ?? "the writer rejected a frame"
        }
    }

    func finish(_ done: @escaping @Sendable (String?) -> Void) {
        if let pending {
            write(pending.unit, time: pending.time, duration: CMTime(value: 400, timescale: 24000))
            self.pending = nil
        }
        input.markAsFinished()
        let box = UncheckedSendable(value: (writer, failure))
        writer.finishWriting {
            let (writer, failure) = box.value
            done(writer.status == .completed ? failure : writer.error?.localizedDescription ?? failure ?? "the video could not be finished")
        }
    }
}

nonisolated final class RecordingSession: @unchecked Sendable {
    private struct Segment {
        var file: String
        var start: Double
        var turns: Int
        var writer: SegmentWriter
    }

    private struct FeedWindow {
        var start: Double
        var frames = 0
        var decoded: Double = 0

        var event: [String: Any] {
            ["time": start, "type": "feed", "frames": frames, "decodedMs": rounded(decoded)]
        }
    }

    static let keyFrameInterval: Double = 2
    static let feedInterval: Double = 250

    let url: URL
    let requested: Double
    private let geometry: ScreenGeometry
    private let lock = NSLock()
    private let tracking = DispatchQueue(label: "io.nekohasekai.swipt.graphics.recording")
    private let tracker = ChangeTracker()
    private let finishing = DispatchGroup()
    private var timeline: LibSwiptGraphicsTimeline?
    private var listeners: [Int] = []
    private var timer: DispatchSourceTimer?
    private var origin: Double?
    private var last: Double = 0
    private var segments: [Segment] = []
    private var writer: SegmentWriter?
    private var format: CMVideoFormatDescription?
    private var waiting = true
    private var stopped = false
    private var failures: [String] = []
    private var queued: Frame?
    private var busy = false
    private var clockDeltas: [Double] = []
    private var window: FeedWindow?
    private var feed: [[String: Any]] = []

    private init(url: URL, geometry: ScreenGeometry, timeline: LibSwiptGraphicsTimeline?) {
        self.url = url
        self.geometry = geometry
        self.timeline = timeline
        requested = nowMilliseconds()
    }

    static func start(url: URL, timeline: LibSwiptGraphicsTimeline?) throws -> RecordingSession {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: VideoModel.sidecar(of: url))
        let geometry = try ScreenFeed.shared.acquire()
        let session = RecordingSession(url: url, geometry: geometry, timeline: timeline)
        let feed = ScreenFeed.shared
        session.listeners = [
            feed.addUnitListener { unit in session.append(unit) },
            feed.addFrameListener { frame in session.observe(frame) },
        ]
        let timer = DispatchSource.makeTimerSource(queue: session.tracking)
        timer.schedule(deadline: .now() + keyFrameInterval, repeating: keyFrameInterval)
        timer.setEventHandler {
            ScreenFeed.shared.requestKeyFrame()
            session.tick()
        }
        timer.resume()
        session.timer = timer
        feed.requestKeyFrame()
        return session
    }

    private func append(_ unit: AccessUnit) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        if unit.damaged {
            waiting = true
            return
        }
        if unit.hasParameterSets, let described = HEVC.format(unit.nals) {
            format = described
        }
        var changed = true
        if let writer, let format {
            changed = writer.turns != unit.turns || !CMFormatDescriptionEqual(format, otherFormatDescription: writer.format)
        }
        if changed {
            if let writer {
                close(writer)
                self.writer = nil
            }
            guard unit.isKeyframe, let format else {
                waiting = true
                return
            }
            if origin == nil {
                origin = unit.arrival
            }
            let index = segments.count
            let base = url.deletingPathExtension().lastPathComponent
            let file = index == 0 ? url.lastPathComponent : "\(base)-\(index + 1).\(url.pathExtension)"
            do {
                let created = try SegmentWriter(url: url.deletingLastPathComponent().appendingPathComponent(file), format: format, turns: unit.turns)
                writer = created
                segments.append(Segment(file: file, start: unit.arrival - origin!, turns: unit.turns, writer: created))
                waiting = false
            } catch {
                failures.append(GraphicsError(error).message)
                return
            }
        }
        if waiting {
            guard unit.isKeyframe else { return }
            waiting = false
        }
        if let writer, let origin, let segment = segments.last {
            let stored = segment.start + writer.append(unit).seconds * 1000
            clockDeltas.append(unit.arrival - origin - stored)
            if clockDeltas.count > 8192 {
                clockDeltas = stride(from: 0, to: clockDeltas.count, by: 2).map { clockDeltas[$0] }
            }
        }
        last = unit.arrival
    }

    private func close(_ writer: SegmentWriter) {
        finishing.enter()
        writer.finish { [self] failure in
            if let failure {
                lock.withLock { failures.append(failure) }
            }
            finishing.leave()
        }
    }

    private func observe(_ frame: Frame) {
        let start: Bool = lock.withLock {
            guard !stopped, let origin, frame.time >= origin else { return false }
            if let window, frame.time >= window.start + RecordingSession.feedInterval {
                feed.append(window.event)
                self.window = nil
            }
            var current = window ?? FeedWindow(start: frame.time)
            current.frames += 1
            current.decoded = max(current.decoded, nowMilliseconds() - frame.time)
            window = current
            queued = frame
            if busy {
                return false
            }
            busy = true
            return true
        }
        if start {
            tracking.async { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            let next: (Frame, Double)? = lock.withLock {
                guard let frame = queued, let origin else {
                    busy = false
                    return nil
                }
                queued = nil
                return (frame, origin)
            }
            guard let next else { return }
            do {
                let plane = try next.0.plane(width: max(next.0.pixelWidth / 4, 1), height: max(next.0.pixelHeight / 4, 1))
                try tracker.push(plane, time: next.0.time - next.1)
            } catch {
                lock.withLock { failures.append(GraphicsError(error).message) }
            }
        }
    }

    private func tick() {
        guard let origin = lock.withLock({ origin }) else { return }
        try? tracker.tick(nowMilliseconds() - origin)
    }

    func stop(token: CancelToken?) throws -> VideoModel {
        let writer: SegmentWriter? = try lock.withLock {
            guard !stopped else {
                throw GraphicsError.state("the recording already stopped")
            }
            stopped = true
            let writer = self.writer
            self.writer = nil
            return writer
        }
        for listener in listeners {
            ScreenFeed.shared.removeListener(listener)
        }
        timer?.cancel()
        if let writer {
            close(writer)
        }
        ScreenFeed.shared.release()
        let events = timeline?.stop() ?? "[]"
        timeline = nil
        while finishing.wait(timeout: .now() + 0.05) == .timedOut {
            try token?.check()
        }
        tracking.sync {
            try? tracker.finish()
        }
        return try save(events)
    }

    func abandon() {
        let running = lock.withLock { !stopped }
        guard running else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                _ = try stop(token: nil)
            } catch {
                let message = GraphicsError(error).message
                Graphics.logger.error("save the abandoned recording: \(message, privacy: .public)")
                Task { @MainActor in
                    ErrorAlert.shared.report(AlertState(String(localized: "Couldn’t Save the Screen Recording"), errorMessage: message))
                }
            }
        }
    }

    private func save(_ timeline: String) throws -> VideoModel {
        let (origin, last, segments, failures, deltas, feed) = lock.withLock { (origin, last, segments, failures, clockDeltas.sorted(), feed + (window.map { [$0.event] } ?? [])) }
        guard let origin, !segments.isEmpty else {
            throw GraphicsError.unavailable("graphics: the recording got no frames; the screen may be off or another app may hold it")
        }
        if let failure = failures.first, segments.allSatisfy({ $0.writer.end == .zero }) {
            throw GraphicsError("Error", "graphics: \(failure)")
        }
        let events = ((try? JSONSerialization.jsonObject(with: Data(timeline.utf8))) as? [[String: Any]] ?? []) + feed
        let foreground = events.filter { $0["type"] as? String == "foreground" }.compactMap { event -> (Double, String)? in
            guard let time = (event["time"] as? NSNumber)?.doubleValue, let app = event["app"] as? String else { return nil }
            return (time, app)
        }
        let duration = max(last - origin, 0) + 1000 / 60
        let changes = tracker.changes.map { change in
            let time = origin + change.start
            let app = foreground.last { $0.0 <= time }?.1 ?? foreground.first?.1
            let turns = segments.last { $0.start <= change.start }?.turns ?? 0
            let width = turns % 2 == 0 ? geometry.width : geometry.height
            return VideoModel.change(change, factor: Double(width) / Double(max(change.width, 1)), scale: geometry.scale, app: app)
        }
        let relative: [[String: Any]] = events.compactMap { event in
            guard let time = (event["time"] as? NSNumber)?.doubleValue, time >= requested - 1000 else { return nil }
            var shifted = event
            shifted["time"] = rounded(time - origin)
            return shifted
        }.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) }
        let metadata: [String: Any] = [
            "version": 1, "start": origin, "duration": rounded(duration), "scale": geometry.scale,
            "clockOffset": rounded(deltas.isEmpty ? 0 : deltas[deltas.count / 2]),
            "screen": ["width": geometry.width, "height": geometry.height],
            "segments": segments.enumerated().map { index, segment in
                let following = index + 1 < segments.count ? segments[index + 1].start : duration
                return ["file": segment.file, "start": rounded(segment.start), "duration": rounded(following - segment.start), "turns": segment.turns] as [String: Any]
            },
            "changes": changes, "events": relative,
        ]
        let sidecar = VideoModel.sidecar(of: url)
        guard let encoded = Outcome.encode(metadata) else {
            throw GraphicsError("Error", "graphics: encode the recording's metadata")
        }
        try Data(encoded.utf8).write(to: sidecar, options: .atomic)
        return try VideoModel(url: url, metadata: metadata)
    }
}
