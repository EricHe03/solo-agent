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
    let pixelWidth: Int
    let pixelHeight: Int
    let transform: CGAffineTransform
    let gray: Bool
    let time: Double?
    let timestamp: Double?

    private let source: ImageSource?
    private let lock = NSLock()
    private var parent: (node: ImageNode, operation: ImageOperation)?
    private var cached: Raster?

    private init(source: ImageSource?, parent: (node: ImageNode, operation: ImageOperation)?, width: Int, height: Int, transform: CGAffineTransform, gray: Bool, time: Double?, timestamp: Double?) {
        self.source = source
        self.parent = parent
        pixelWidth = width
        pixelHeight = height
        self.transform = transform
        self.gray = gray
        self.time = time
        self.timestamp = timestamp
    }

    static func encoded(_ data: Data, scale: Double?, timestamp: Double?) throws -> ImageNode {
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
        return ImageNode(source: .encoded(data), parent: nil, width: width, height: height,
                         transform: CGAffineTransform(scaleX: 1 / chosen, y: 1 / chosen), gray: false, time: nil, timestamp: timestamp)
    }

    static func frame(_ frame: Frame, of model: VideoModel? = nil) -> ImageNode {
        ImageNode(source: .frame(frame), parent: nil, width: frame.pixelWidth, height: frame.pixelHeight,
                  transform: CGAffineTransform(scaleX: 1 / frame.geometry.scale, y: 1 / frame.geometry.scale), gray: false,
                  time: model == nil ? nil : frame.time, timestamp: model == nil ? frame.time : model!.start.map { $0 + frame.time })
    }

    static func video(_ model: VideoModel, time: Double) -> ImageNode {
        let size = model.pixelSize(at: time)
        return ImageNode(source: .video(model, time), parent: nil, width: size.width, height: size.height,
                         transform: CGAffineTransform(scaleX: 1 / model.scale, y: 1 / model.scale), gray: false, time: time, timestamp: model.start.map { $0 + time })
    }

    static func raster(_ raster: Raster, transform: CGAffineTransform) -> ImageNode {
        ImageNode(source: .raster(raster), parent: nil, width: raster.width, height: raster.height,
                  transform: transform, gray: raster.isGray, time: nil, timestamp: nil)
    }

    private func derive(_ operation: ImageOperation, width: Int, height: Int, transform: CGAffineTransform? = nil, gray: Bool? = nil) -> ImageNode {
        ImageNode(source: nil, parent: (self, operation), width: width, height: height,
                  transform: transform ?? self.transform, gray: gray ?? self.gray, time: time, timestamp: timestamp)
    }

    var scale: Double {
        1 / abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
    }

    var frame: CGRect {
        CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).applying(transform)
    }

    var screenFrame: Frame? {
        if case .frame(let frame) = source {
            return frame
        }
        return nil
    }

    var estimatedBytes: Int {
        pixelWidth * pixelHeight * (gray ? 1 : 4)
    }

    func pixelRect(space rect: CGRect) throws -> CGRect {
        let mapped = rect.applying(transform.inverted()).intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        let left = floor(mapped.minX + 1e-6)
        let top = floor(mapped.minY + 1e-6)
        let right = ceil(mapped.maxX - 1e-6)
        let bottom = ceil(mapped.maxY - 1e-6)
        guard !mapped.isNull, right - left >= 1, bottom - top >= 1 else {
            let described = { (rect: CGRect) in rectJSON(rect).map { String(format: "%g", $0) }.joined(separator: ", ") }
            throw GraphicsError.range("[\(described(rect))] does not overlap the image [\(described(frame))]")
        }
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
        let pixels = try pixelRect(space: rect)
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

    func raster(_ token: CancelToken? = nil) throws -> Raster {
        if let cached = lock.withLock({ cached }) {
            return cached
        }
        let rendered = try render(token)
        lock.withLock {
            cached = rendered
            parent = nil
        }
        return rendered
    }

    private func render(_ token: CancelToken?) throws -> Raster {
        guard let source else {
            guard let parent = lock.withLock({ parent }) else {
                return try raster(token)
            }
            let input = try parent.node.lock.withLock({ parent.node.cached }) ?? parent.node.render(token)
            try token?.check()
            return try perform(parent.operation, on: input)
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
        lock.withLock { cached = raster }
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
