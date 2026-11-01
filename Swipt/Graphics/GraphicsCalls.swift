import CoreGraphics
import Foundation
import LibSwipt

nonisolated enum GraphicsCalls {
    private static let defaultThreshold = 24

    static func execute(_ call: PreparedCall, engine: GraphicsEngine, context: LibSwiptGraphicsContext, token: CancelToken) throws -> Any {
        let arguments = call.arguments
        switch call.method {
        case "screenshot":
            return try screenshot(engine, context, token)
        case "screen.get":
            return try screen(engine, token)
        case "screen.waitForChange":
            return try waitForChange(call, engine, token)
        case "screen.waitForStable":
            return try waitForStable(call, engine, token)
        case "screen.find":
            return try screenFind(call, engine, token)
        case "decode":
            return try decode(call, engine)
        case "encode":
            let node = try image(call, 0)
            let data = try node.raster(token).encode(arguments.string("format") ?? "png", quality: arguments.double("quality"), scale: node.scale)
            return ["bytes": engine.register(data)]
        case "save":
            let node = try image(call, 0)
            let data = try node.raster(token).encode(arguments.string("format") ?? "png", quality: arguments.double("quality"), scale: node.scale)
            let url = URL(fileURLWithPath: arguments.string("path") ?? "")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return [String: Any]()
        case "pixel":
            return try pixel(call, token)
        case "stats":
            let node = try image(call, 0)
            return try region(node, arguments.rect("region"), token).statistics()
        case "find":
            return try find(call, token)
        case "colors":
            return try colors(call, token)
        case "components":
            let node = try image(call, 0)
            let binary = try Regions.binarized(node.raster(token))
            return try Regions.components(binary, minimumPixels: arguments.int("minimumPixels") ?? 1, token: token).map { component in
                ["frame": rectJSON(node.spaceRect(component.rect)), "pixels": component.count, "centroid": node.spacePoint(component.centroid)] as [String: Any]
            }
        case "text":
            let text = try Recognition.text(image(call, 0), arguments, token: token)
            return ["lines": text.lines, "text": engine.register(text)]
        case "diff":
            return try difference(image(call, 0), image(call, 1), threshold: arguments.int("threshold") ?? defaultThreshold, token: token)
        case "distance":
            return try rounded(Recognition.distance(Recognition.featurePrint(image(call, 0), token: token), image(call, 1), token: token) * 1000) / 1000
        case "nearest":
            let reference = try Recognition.featurePrint(image(call, 0), token: token)
            var best: (index: Int, distance: Double)?
            for index in 1..<call.objects.count {
                let distance = try Recognition.distance(reference, image(call, index), token: token)
                if best == nil || distance < best!.distance {
                    best = (index - 1, distance)
                }
            }
            guard let found = best else { throw GraphicsError.type("nearest needs candidates") }
            return ["index": found.index, "distance": rounded(found.distance * 1000) / 1000]
        case "barcodes":
            return try Recognition.barcodes(image(call, 0), token: token)
        case "record":
            let url = URL(fileURLWithPath: arguments.string("path") ?? "")
            let session = try RecordingSession.start(url: url, timeline: context.watchTimeline())
            return ["recording": engine.register(session)]
        case "recording.stop":
            guard let session = call.objects.first as? RecordingSession else { throw GraphicsError.type("stop needs a Recording") }
            return try ["video": engine.register(session.stop(token: token))]
        case "video.open":
            let url = URL(fileURLWithPath: arguments.string("path") ?? "")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GraphicsError("NotFoundError", "there is no file at \(url.path)")
            }
            return try ["video": engine.register(VideoModel.open(url, token: token))]
        case "video.grid":
            let model = try video(call)
            let times = arguments.doubles("times") ?? model.defaultGridTimes()
            let grid = try model.grid(times: times, columns: arguments.int("columns") ?? 4, width: arguments.int("width") ?? 240, token: token)
            return ["image": engine.register(ImageNode.raster(grid, transform: .identity))]
        case "video.diff":
            let model = try video(call)
            return try difference(model.node(at: arguments.double("from") ?? 0), model.node(at: arguments.double("to") ?? 0),
                                  threshold: arguments.int("threshold") ?? defaultThreshold, token: token)
        case "video.export":
            return try ["path": video(call).export(arguments, token: token)]
        default:
            throw GraphicsError.type("graphics: there is no call \(call.method)")
        }
    }

    static func watch(_ call: PreparedCall, engine: GraphicsEngine, token: CancelToken, publish: (String) -> Void) throws {
        guard call.method == "screen.watch" else {
            throw GraphicsError.type("graphics: there is no stream \(call.method)")
        }
        let feed = ScreenFeed.shared
        _ = try feed.acquire()
        defer { feed.release() }
        var sequence = 0
        var previous: Int?
        defer {
            if let previous {
                engine.drop(previous)
            }
        }
        while true {
            guard let next = try feed.frame(after: sequence, until: .distantFuture, token: token) else { continue }
            sequence = next.1
            let id = engine.register(ImageNode.frame(next.0))
            if let previous {
                engine.drop(previous)
            }
            previous = id
            publish(String(id))
        }
    }

    private static func image(_ call: PreparedCall, _ index: Int) throws -> ImageNode {
        guard index < call.objects.count, let node = call.objects[index] as? ImageNode else {
            throw GraphicsError.type("graphics: argument \(index + 1) of \(call.method) is not an Image")
        }
        return node
    }

    private static func video(_ call: PreparedCall) throws -> VideoModel {
        guard let model = call.objects.first as? VideoModel else {
            throw GraphicsError.type("graphics: \(call.method) needs a Video")
        }
        return model
    }

    private static func region(_ node: ImageNode, _ rect: CGRect?, _ token: CancelToken) throws -> Raster {
        let raster = try node.raster(token)
        guard let rect else { return raster }
        guard let pixels = node.pixelRect(space: rect) else {
            throw GraphicsError.range("the region lies outside the image")
        }
        return raster.view(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height))
    }

    private static func screenshot(_ engine: GraphicsEngine, _ context: LibSwiptGraphicsContext, _ token: CancelToken) throws -> Any {
        let started = nowMilliseconds()
        guard let shot = context.screenshot() else {
            throw GraphicsError.unavailable("graphics: the device sent no screenshot")
        }
        if !shot.failure.isEmpty {
            throw GraphicsError(failure: shot.failure)
        }
        guard let data = shot.image, !data.isEmpty else {
            throw GraphicsError.unavailable("graphics: the device sent no screenshot")
        }
        try token.check()
        return try ["image": engine.register(ImageNode.encoded(data, scale: shot.scale > 0 ? shot.scale : nil, time: started))]
    }

    private static func firstFrame(_ feed: ScreenFeed, _ token: CancelToken) throws -> (Frame, Int) {
        if let latest = feed.latestFrame() {
            return latest
        }
        guard let next = try feed.frame(after: 0, until: Date().addingTimeInterval(ScreenFeed.firstFrameLimit), token: token) else {
            throw GraphicsError.unavailable("graphics: the screen sent no frame within \(Int(ScreenFeed.firstFrameLimit)) s; it may be off")
        }
        return next
    }

    private static func screen(_ engine: GraphicsEngine, _ token: CancelToken) throws -> Any {
        let feed = ScreenFeed.shared
        _ = try feed.acquire()
        defer { feed.release() }
        return try ["image": engine.register(ImageNode.frame(firstFrame(feed, token).0))]
    }

    private struct Comparison {
        let region: CGRect
        let width: Int
        let height: Int
        let threshold: Int

        init(_ node: ImageNode, region: CGRect?, threshold: Int) throws {
            let area = region ?? node.frame
            guard let pixels = node.pixelRect(space: area) else {
                throw GraphicsError.range("the region lies outside the screen")
            }
            let factor = min(pixels.width, pixels.height) >= 64 ? 4.0 : 1.0
            self.region = area
            width = max(Int(pixels.width / factor), 1)
            height = max(Int(pixels.height / factor), 1)
            self.threshold = threshold
        }

        func plane(_ node: ImageNode, _ token: CancelToken) throws -> Raster {
            let raster = try node.raster(token)
            guard let pixels = node.pixelRect(space: region) else {
                throw GraphicsError.range("the region lies outside the screen")
            }
            return try raster.view(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height))
                .resized(width: width, height: height).grayscale()
        }

        func changed(_ a: Raster, _ b: Raster) throws -> Bool {
            try Regions.difference(a, b, threshold: threshold).changed >= Regions.minimumChange(a.width * a.height)
        }
    }

    private static func deadline(_ arguments: Arguments) -> Date {
        let timeout = arguments.timeout()
        return timeout.isFinite ? Date().addingTimeInterval(timeout / 1000) : .distantFuture
    }

    private static func waitForChange(_ call: PreparedCall, _ engine: GraphicsEngine, _ token: CancelToken) throws -> Any {
        let arguments = call.arguments
        let limit = deadline(arguments)
        let feed = ScreenFeed.shared
        _ = try feed.acquire()
        defer { feed.release() }
        var (frame, sequence) = try firstFrame(feed, token)
        let reference = call.objects.first as? ImageNode ?? ImageNode.frame(frame)
        let comparison = try Comparison(reference, region: arguments.rect("region"), threshold: arguments.int("threshold") ?? defaultThreshold)
        let before = try comparison.plane(reference, token)
        if call.objects.first != nil {
            let node = ImageNode.frame(frame)
            if try comparison.changed(before, comparison.plane(node, token)) {
                return ["image": engine.register(node)]
            }
        }
        while true {
            guard let next = try feed.frame(after: sequence, until: limit, token: token) else {
                throw GraphicsError.timeout("the screen did not change within \(Int(arguments.timeout())) ms")
            }
            (frame, sequence) = next
            let node = ImageNode.frame(frame)
            if try comparison.changed(before, comparison.plane(node, token)) {
                return ["image": engine.register(node)]
            }
        }
    }

    private static func waitForStable(_ call: PreparedCall, _ engine: GraphicsEngine, _ token: CancelToken) throws -> Any {
        let arguments = call.arguments
        let limit = deadline(arguments)
        let quiet = (arguments.double("durationMs") ?? 500) / 1000
        let feed = ScreenFeed.shared
        _ = try feed.acquire()
        defer { feed.release() }
        var (frame, sequence) = try firstFrame(feed, token)
        var node = ImageNode.frame(frame)
        let comparison = try Comparison(node, region: arguments.rect("region"), threshold: arguments.int("threshold") ?? defaultThreshold)
        var last = try comparison.plane(node, token)
        var changedAt = Date()
        while true {
            let remaining = quiet - Date().timeIntervalSince(changedAt)
            if remaining <= 0 {
                return ["image": engine.register(node)]
            }
            if Date() >= limit {
                throw GraphicsError.timeout("the screen did not settle within \(Int(arguments.timeout())) ms")
            }
            guard let next = try feed.frame(after: sequence, until: min(limit, Date().addingTimeInterval(remaining)), token: token) else { continue }
            (frame, sequence) = next
            node = ImageNode.frame(frame)
            let current = try comparison.plane(node, token)
            if try comparison.changed(last, current) {
                changedAt = Date()
            }
            last = current
        }
    }

    private enum ScreenTarget {
        case image(ImageNode)
        case text(NSRegularExpression)
    }

    private struct ScreenHit {
        let frame: CGRect
        let score: Double
        let text: String?
        let target: Int
    }

    private static func screenTargets(_ call: PreparedCall) throws -> [ScreenTarget] {
        var targets: [ScreenTarget] = []
        var images = 0
        for entry in call.arguments.objects("targets") {
            if entry["kind"] as? String == "text" {
                guard let pattern = entry["pattern"] as? String else {
                    throw GraphicsError.type("graphics: a text target needs a pattern")
                }
                var options: NSRegularExpression.Options = []
                if (entry["flags"] as? String ?? "").contains("i") {
                    options.insert(.caseInsensitive)
                }
                targets.append(.text(try NSRegularExpression(pattern: pattern, options: options)))
            } else {
                targets.append(.image(try image(call, images)))
                images += 1
            }
        }
        guard !targets.isEmpty else {
            throw GraphicsError.type("graphics: find needs a target")
        }
        return targets
    }

    private static func probe(_ node: ImageNode, _ targets: [ScreenTarget], _ arguments: Arguments, _ token: CancelToken) throws -> ScreenHit? {
        let region = arguments.rect("region")
        let raster = try node.raster(token)
        var target = raster
        var origin = CGPoint.zero
        if let region {
            guard let pixels = node.pixelRect(space: region) else { return nil }
            target = raster.view(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height))
            origin = pixels.origin
        }
        let threshold = arguments.double("threshold") ?? 0.8
        let binarize = arguments.int("binarize")
        var binaryTarget: Raster?
        var recognized: RecognizedText?
        for (index, entry) in targets.enumerated() {
            try token.check()
            switch entry {
            case .image(let template):
                let base = node.scale / template.scale
                let factors = (arguments.doubles("scales") ?? [1]).map { $0 * base }
                var searched = target
                var pattern = try template.raster(token)
                if let binarize {
                    if binaryTarget == nil {
                        binaryTarget = try target.grayscale().thresholded(binarize)
                    }
                    searched = binaryTarget!
                    pattern = try pattern.grayscale().thresholded(binarize)
                }
                let matches = try TemplateMatching.find(
                    target: searched, template: pattern, factors: factors, threshold: threshold, limit: 1, overlap: 0.3, token: token)
                if let match = matches.first {
                    return ScreenHit(frame: node.spaceRect(match.rect.offsetBy(dx: origin.x, dy: origin.y)), score: match.score, text: nil, target: index)
                }
            case .text(let expression):
                if recognized == nil {
                    var values: [String: Any] = ["level": "accurate", "correction": false]
                    if let region = arguments.values["region"] {
                        values["region"] = region
                    }
                    for key in ["languages", "minimumHeight"] {
                        if let value = arguments.values[key] {
                            values[key] = value
                        }
                    }
                    recognized = try Recognition.text(node, Arguments(values: values), token: token)
                }
                for (line, entry) in recognized!.lines.enumerated() {
                    guard let text = entry["text"] as? String,
                          let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
                    let box = (try? recognized!.boundingBox(line: line, candidate: 0, start: match.range.location, end: match.range.location + match.range.length)) ?? nil
                    guard let numbers = (box ?? entry)["frame"] as? [Double], numbers.count == 4 else { continue }
                    let confidence = (entry["confidence"] as? NSNumber)?.doubleValue ?? 0
                    return ScreenHit(frame: CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), score: confidence, text: (text as NSString).substring(with: match.range), target: index)
                }
            }
        }
        return nil
    }

    private static func screenFind(_ call: PreparedCall, _ engine: GraphicsEngine, _ token: CancelToken) throws -> Any {
        let arguments = call.arguments
        let targets = try screenTargets(call)
        let timeout = arguments.values["timeoutMs"] == nil ? 0 : arguments.timeout()
        let limit: Date = timeout.isFinite ? Date().addingTimeInterval(timeout / 1000) : .distantFuture
        let feed = ScreenFeed.shared
        _ = try feed.acquire()
        defer { feed.release() }
        var (frame, sequence) = try firstFrame(feed, token)
        var comparison: Comparison?
        var previous: Raster?
        while true {
            try token.check()
            let node = ImageNode.frame(frame)
            if comparison == nil {
                comparison = try Comparison(node, region: arguments.rect("region"), threshold: defaultThreshold)
            }
            let plane = try comparison!.plane(node, token)
            let changed = try previous.map { try comparison!.changed($0, plane) } ?? true
            previous = plane
            if changed, let hit = try probe(node, targets, arguments, token) {
                return [
                    "frame": rectJSON(hit.frame), "center": centerJSON(hit.frame), "score": (hit.score * 1000).rounded() / 1000,
                    "text": hit.text.map { $0 as Any } ?? NSNull(), "target": hit.target, "image": engine.register(node),
                ] as [String: Any]
            }
            if timeout == 0 {
                return NSNull()
            }
            guard let next = try feed.frame(after: sequence, until: limit, token: token) else {
                return NSNull()
            }
            (frame, sequence) = next
        }
    }

    private static func decode(_ call: PreparedCall, _ engine: GraphicsEngine) throws -> Any {
        let arguments = call.arguments
        var scale = arguments.double("scale")
        let data: Data
        if let bytes = call.objects.first as? Data {
            data = bytes
        } else if let path = arguments.string("path") {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                throw GraphicsError("NotFoundError", "there is no file at \(path)")
            }
            data = try Data(contentsOf: url)
            if scale == nil, let match = url.lastPathComponent.firstMatch(of: /@(\d+(?:\.\d+)?)x\.[^.]+$/) {
                scale = Double(match.1)
            }
        } else {
            throw GraphicsError.type("decode needs bytes or a file")
        }
        let node = try ImageNode.encoded(data, scale: scale, time: nil)
        return ["image": engine.register(node)]
    }

    private static func pixel(_ call: PreparedCall, _ token: CancelToken) throws -> Any {
        let node = try image(call, 0)
        guard let point = call.arguments.point("point") else { throw GraphicsError.type("pixel needs a point") }
        let location = node.pixelPoint(space: point)
        let x = Int(location.x.rounded(.down))
        let y = Int(location.y.rounded(.down))
        guard x >= 0, y >= 0, x < node.pixelWidth, y < node.pixelHeight else {
            throw GraphicsError.range("the point lies outside the image")
        }
        return try node.raster(token).pixel(x: x, y: y)
    }

    private static func find(_ call: PreparedCall, _ token: CancelToken) throws -> Any {
        let arguments = call.arguments
        let node = try image(call, 0)
        let template = try image(call, 1)
        let raster = try node.raster(token)
        var target = raster
        var origin = CGPoint.zero
        if let rect = arguments.rect("region") {
            guard let pixels = node.pixelRect(space: rect) else { return [Any]() }
            target = raster.view(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height))
            origin = pixels.origin
        }
        let base = node.scale / template.scale
        let factors = (arguments.doubles("scales") ?? [1]).map { $0 * base }
        let matches = try TemplateMatching.find(
            target: target, template: template.raster(token), factors: factors, threshold: arguments.double("threshold") ?? 0.8,
            limit: arguments.int("limit") ?? 100, overlap: arguments.double("overlap") ?? 0.3, token: token)
        return matches.map { match in
            let frame = node.spaceRect(match.rect.offsetBy(dx: origin.x, dy: origin.y))
            return ["frame": rectJSON(frame), "center": centerJSON(frame), "score": (match.score * 1000).rounded() / 1000, "scale": rounded(match.scale / base)] as [String: Any]
        }
    }

    private static func colors(_ call: PreparedCall, _ token: CancelToken) throws -> Any {
        let node = try image(call, 0)
        let raster = try node.raster(token)
        return call.arguments.objects("checks").map { check -> Bool in
            guard let coordinates = check["point"] as? [NSNumber], coordinates.count == 2,
                  let color = check["color"] as? [NSNumber], color.count == 3 else { return false }
            let location = node.pixelPoint(space: CGPoint(x: coordinates[0].doubleValue, y: coordinates[1].doubleValue))
            let x = Int(location.x.rounded(.down))
            let y = Int(location.y.rounded(.down))
            guard x >= 0, y >= 0, x < raster.width, y < raster.height else { return false }
            let tolerance = (check["tolerance"] as? NSNumber)?.intValue ?? 16
            let pixel = raster.pixel(x: x, y: y)
            return (0..<3).allSatisfy { abs(pixel[$0] - color[$0].intValue) <= tolerance }
        }
    }

    static func difference(_ first: ImageNode, _ second: ImageNode, threshold: Int, token: CancelToken) throws -> Any {
        let a = try first.raster(token)
        let b = try second.raster(token).resized(width: a.width, height: a.height)
        let difference = try Regions.difference(a, b, threshold: threshold)
        let regions = try Regions.regions(difference.mask, merge: max(2, a.width / 200), token: token)
        return [
            "ratio": (Double(difference.changed) / Double(max(a.width * a.height, 1)) * 10000).rounded() / 10000,
            "frames": regions.map { rectJSON(first.spaceRect($0)) },
        ]
    }
}
