import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ImageSource: @unchecked Sendable {
    case encoded(Data)
    case frame(Frame)
    case video(VideoModel, Double)
    case raster(Raster)
}

nonisolated enum ImageOperation: Sendable {
    case crop(x: Int, y: Int, width: Int, height: Int)
    case resize(width: Int, height: Int)
    case rotate(degrees: Double)
    case grayscale
    case threshold(level: Int)
    case mask(low: [UInt8], high: [UInt8])
    case invert
    case dilate(radius: Int)
    case erode(radius: Int)
}

nonisolated final class ImageNode: @unchecked Sendable {
    let parent: ImageNode?
    let operation: ImageOperation?
    let pixelWidth: Int
    let pixelHeight: Int
    let transform: CGAffineTransform
    let gray: Bool
    let time: Double?

    private let lock = NSLock()
    private var source: ImageSource?
    private var cached: Raster?
    private var released = false

    private init(source: ImageSource?, parent: ImageNode?, operation: ImageOperation?, width: Int, height: Int, transform: CGAffineTransform, gray: Bool, time: Double?) {
        self.source = source
        self.parent = parent
        self.operation = operation
        pixelWidth = width
        pixelHeight = height
        self.transform = transform
        self.gray = gray
        self.time = time
    }

    static func encoded(_ data: Data, scale: Double?, time: Double?) throws -> ImageNode {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0
        else {
            throw GraphicsError.data("graphics: the bytes are not an image")
        }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
            swap(&width, &height)
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        let chosen = scale ?? dpi.map { $0 / 72 }.flatMap { $0 >= 1 && $0 <= 16 ? $0 : nil } ?? 1
        return ImageNode(source: .encoded(data), parent: nil, operation: nil, width: width, height: height,
                         transform: CGAffineTransform(scaleX: 1 / chosen, y: 1 / chosen), gray: false, time: time)
    }

    static func frame(_ frame: Frame) -> ImageNode {
        ImageNode(source: .frame(frame), parent: nil, operation: nil, width: frame.pixelWidth, height: frame.pixelHeight,
                  transform: CGAffineTransform(scaleX: 1 / frame.geometry.scale, y: 1 / frame.geometry.scale), gray: false, time: frame.time)
    }

    static func video(_ model: VideoModel, time: Double) -> ImageNode {
        let size = model.pixelSize(at: time)
        let start = model.start.map { $0 + time }
        return ImageNode(source: .video(model, time), parent: nil, operation: nil, width: size.width, height: size.height,
                         transform: CGAffineTransform(scaleX: 1 / model.scale, y: 1 / model.scale), gray: false, time: start)
    }

    static func raster(_ raster: Raster, transform: CGAffineTransform, time: Double? = nil) -> ImageNode {
        ImageNode(source: .raster(raster), parent: nil, operation: nil, width: raster.width, height: raster.height,
                  transform: transform, gray: raster.isGray, time: time)
    }

    private func derive(_ operation: ImageOperation, width: Int, height: Int, transform: CGAffineTransform? = nil, gray: Bool? = nil) -> ImageNode {
        ImageNode(source: nil, parent: self, operation: operation, width: width, height: height,
                  transform: transform ?? self.transform, gray: gray ?? self.gray, time: time)
    }

    var scale: Double {
        1 / abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
    }

    var frame: CGRect {
        CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).applying(transform)
    }

    var screenFrame: Frame? {
        lock.withLock {
            if parent == nil, case .frame(let frame) = source {
                return frame
            }
            return nil
        }
    }

    var estimatedBytes: Int {
        pixelWidth * pixelHeight * (gray ? 1 : 4)
    }

    func pixelRect(space rect: CGRect) -> CGRect? {
        let mapped = rect.applying(transform.inverted()).intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard !mapped.isNull else { return nil }
        let left = floor(mapped.minX + 1e-6)
        let top = floor(mapped.minY + 1e-6)
        let right = ceil(mapped.maxX - 1e-6)
        let bottom = ceil(mapped.maxY - 1e-6)
        guard right - left >= 1, bottom - top >= 1 else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func pixelPoint(space point: CGPoint) -> CGPoint {
        point.applying(transform.inverted())
    }

    func spacePoint(_ point: CGPoint) -> [Double] {
        pointJSON(point.applying(transform))
    }

    func spaceRect(_ rect: CGRect) -> CGRect {
        rect.applying(transform)
    }

    func crop(space rect: CGRect) throws -> ImageNode {
        guard let pixels = pixelRect(space: rect) else {
            throw GraphicsError.range("the rect lies outside the image")
        }
        return derive(.crop(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height)),
                      width: Int(pixels.width), height: Int(pixels.height),
                      transform: CGAffineTransform(translationX: pixels.minX, y: pixels.minY).concatenating(transform))
    }

    func resize(width: Int, height: Int) -> ImageNode {
        derive(.resize(width: width, height: height), width: width, height: height,
               transform: CGAffineTransform(scaleX: CGFloat(pixelWidth) / CGFloat(width), y: CGFloat(pixelHeight) / CGFloat(height)).concatenating(transform))
    }

    func rotate(degrees: Double) -> ImageNode {
        let turned = degrees.truncatingRemainder(dividingBy: 360)
        let normalized = turned < 0 ? turned + 360 : turned
        if normalized == 0 {
            return self
        }
        let angle = normalized * .pi / 180
        let quarter = normalized.truncatingRemainder(dividingBy: 90) == 0
        let width = quarter ? (Int(normalized) / 90 % 2 == 0 ? pixelWidth : pixelHeight)
            : Int((abs(Double(pixelWidth) * cos(angle)) + abs(Double(pixelHeight) * sin(angle)) - 1e-6).rounded(.up))
        let height = quarter ? (Int(normalized) / 90 % 2 == 0 ? pixelHeight : pixelWidth)
            : Int((abs(Double(pixelWidth) * sin(angle)) + abs(Double(pixelHeight) * cos(angle)) - 1e-6).rounded(.up))
        let toParent = CGAffineTransform(translationX: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(translationX: CGFloat(pixelWidth) / 2, y: CGFloat(pixelHeight) / 2))
        return derive(.rotate(degrees: normalized), width: max(width, 1), height: max(height, 1), transform: toParent.concatenating(transform))
    }

    func apply(_ operation: ImageOperation) -> ImageNode {
        switch operation {
        case .grayscale, .threshold, .mask:
            derive(operation, width: pixelWidth, height: pixelHeight, gray: true)
        default:
            derive(operation, width: pixelWidth, height: pixelHeight)
        }
    }

    func release() {
        lock.withLock {
            released = true
            cached = nil
            source = nil
        }
    }

    func raster(_ token: CancelToken? = nil) throws -> Raster {
        if let cached = try peek() {
            return cached
        }
        let rendered = try render(token)
        lock.withLock {
            if !released {
                cached = rendered
            }
        }
        return rendered
    }

    private func peek() throws -> Raster? {
        try lock.withLock {
            if released {
                throw GraphicsError.released
            }
            return cached
        }
    }

    private func render(_ token: CancelToken?) throws -> Raster {
        if let parent, let operation {
            let input = try parent.peek() ?? parent.render(token)
            try token?.check()
            return try perform(operation, on: input)
        }
        guard let source = lock.withLock({ source }) else {
            throw GraphicsError.released
        }
        var raster: Raster = switch source {
        case .encoded(let data): try Raster.decode(data)
        case .frame(let frame): try frame.raster()
        case .video(let model, let time): try model.raster(at: time, token: token)
        case .raster(let raster): raster
        }
        if raster.width != pixelWidth || raster.height != pixelHeight {
            raster = try raster.resized(width: pixelWidth, height: pixelHeight)
        }
        lock.withLock {
            if !released {
                cached = raster
            }
        }
        return raster
    }

    private func perform(_ operation: ImageOperation, on input: Raster) throws -> Raster {
        switch operation {
        case .crop(let x, let y, let width, let height):
            return input.view(x: x, y: y, width: width, height: height)
        case .resize(let width, let height):
            return try input.resized(width: width, height: height)
        case .rotate(let degrees):
            if degrees.truncatingRemainder(dividingBy: 90) == 0 {
                return try input.rotated(quarterTurns: Int(degrees) / 90)
            }
            return try input.rotated(degrees: degrees, width: pixelWidth, height: pixelHeight)
        case .grayscale:
            return try input.grayscale()
        case .threshold(let level):
            return try input.thresholded(level)
        case .mask(let low, let high):
            return try input.masked(low: low, high: high)
        case .invert:
            return try input.inverted()
        case .dilate(let radius):
            return try input.morphed(radius: radius, dilate: true)
        case .erode(let radius):
            return try input.morphed(radius: radius, dilate: false)
        }
    }
}
