import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated final class RasterStorage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    private let pixelBuffer: CVPixelBuffer?
    private let allocated: Bool

    init(byteCount: Int) {
        base = UnsafeMutableRawPointer.allocate(byteCount: max(byteCount, 1), alignment: 64)
        pixelBuffer = nil
        allocated = true
    }

    init(adopting base: UnsafeMutableRawPointer) {
        self.base = base
        pixelBuffer = nil
        allocated = false
    }

    init(pixelBuffer: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw GraphicsError("Error", "graphics: lock the frame")
        }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            throw GraphicsError("Error", "graphics: the frame has no pixels")
        }
        self.base = base
        self.pixelBuffer = pixelBuffer
        allocated = false
    }

    deinit {
        if let pixelBuffer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        } else if allocated {
            base.deallocate()
        } else {
            free(base)
        }
    }
}

nonisolated final class Raster: @unchecked Sendable {
    let storage: RasterStorage
    let data: UnsafeMutableRawPointer
    let width: Int
    let height: Int
    let rowBytes: Int
    let channels: Int

    init(width: Int, height: Int, channels: Int) {
        let rowBytes = (width * channels + 15) & ~15
        storage = RasterStorage(byteCount: rowBytes * height)
        data = storage.base
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.channels = channels
    }

    init(storage: RasterStorage, data: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int, channels: Int) {
        self.storage = storage
        self.data = data
        self.width = width
        self.height = height
        self.rowBytes = rowBytes
        self.channels = channels
    }

    var isGray: Bool { channels == 1 }

    var buffer: vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
    }

    func row(_ y: Int) -> UnsafeMutablePointer<UInt8> {
        (data + y * rowBytes).assumingMemoryBound(to: UInt8.self)
    }

    static func colorFormat() -> vImage_CGImageFormat {
        vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))!
    }

    static func grayFormat() -> vImage_CGImageFormat {
        vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 8, colorSpace: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))!
    }

    static func decode(_ data: Data) throws -> Raster {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw GraphicsError.data("graphics: the bytes are not an image")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image: CGImage?
        if orientation == 1 {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let side = max((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0, (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(side, 1), kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        guard let image else {
            throw GraphicsError.data("graphics: the image could not be decoded")
        }
        return try Raster(image: image)
    }

    convenience init(image: CGImage) throws {
        let decoded = try vImage_Buffer(cgImage: image, format: Raster.colorFormat())
        let storage = RasterStorage(adopting: decoded.data)
        self.init(storage: storage, data: storage.base, width: Int(decoded.width), height: Int(decoded.height), rowBytes: decoded.rowBytes, channels: 4)
    }

    func cgImage() throws -> CGImage {
        try buffer.createCGImage(format: isGray ? Raster.grayFormat() : Raster.colorFormat())
    }

    func encode(_ format: String, quality: Double?, scale: Double) throws -> Data {
        let image = try cgImage()
        let type: UTType = switch format {
        case "jpeg": .jpeg
        case "heic": .heic
        default: .png
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else {
            throw GraphicsError("Error", "graphics: create the \(format) encoder")
        }
        var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        if let quality {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw GraphicsError("Error", "graphics: encode the image as \(format)")
        }
        return data as Data
    }

    func view(x: Int, y: Int, width: Int, height: Int) -> Raster {
        Raster(storage: storage, data: data + y * rowBytes + x * channels, width: width, height: height, rowBytes: rowBytes, channels: channels)
    }

    func resized(width: Int, height: Int) throws -> Raster {
        if width == self.width && height == self.height {
            return self
        }
        let out = Raster(width: width, height: height, channels: channels)
        var source = buffer
        var destination = out.buffer
        let flags = vImage_Flags(kvImageHighQualityResampling)
        try require(isGray ? vImageScale_Planar8(&source, &destination, nil, flags) : vImageScale_ARGB8888(&source, &destination, nil, flags), "resize the image")
        return out
    }

    func rotated(quarterTurns: Int) throws -> Raster {
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns == 0 {
            return self
        }
        let out = turns % 2 == 0 ? Raster(width: width, height: height, channels: channels) : Raster(width: height, height: width, channels: channels)
        let constant = UInt8([kRotate0DegreesClockwise, kRotate90DegreesClockwise, kRotate180DegreesClockwise, kRotate270DegreesClockwise][turns])
        var source = buffer
        var destination = out.buffer
        if isGray {
            try require(vImageRotate90_Planar8(&source, &destination, constant, 0, vImage_Flags(kvImageNoFlags)), "rotate the image")
        } else {
            var back: [UInt8] = [0, 0, 0, 0]
            try require(vImageRotate90_ARGB8888(&source, &destination, constant, &back, vImage_Flags(kvImageNoFlags)), "rotate the image")
        }
        return out
    }

    func rotated(degrees: Double, width outWidth: Int, height outHeight: Int) throws -> Raster {
        let out = Raster(width: outWidth, height: outHeight, channels: channels)
        memset(out.data, 0, out.rowBytes * outHeight)
        let image = try cgImage()
        let space = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: out.data, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: out.rowBytes, space: space, bitmapInfo: info) else {
            throw GraphicsError("Error", "graphics: create the drawing context")
        }
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(outHeight))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(outWidth) / 2, y: CGFloat(outHeight) / 2)
        context.rotate(by: degrees * .pi / 180)
        context.translateBy(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if !isGray {
            var source = out.buffer
            var destination = out.buffer
            try require(vImageUnpremultiplyData_RGBA8888(&source, &destination, vImage_Flags(kvImageNoFlags)), "unpremultiply the image")
        }
        return out
    }

    func grayscale() throws -> Raster {
        if isGray {
            return self
        }
        let out = Raster(width: width, height: height, channels: 1)
        var source = buffer
        var destination = out.buffer
        let matrix: [Int16] = [29, 150, 77, 0]
        try require(vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags)), "convert the image to gray")
        return out
    }

    func lookUp(_ table: [UInt8]) throws -> Raster {
        let gray = try grayscale()
        let out = Raster(width: width, height: height, channels: 1)
        var source = gray.buffer
        var destination = out.buffer
        try require(vImageTableLookUp_Planar8(&source, &destination, table, vImage_Flags(kvImageNoFlags)), "map the image")
        return out
    }

    func thresholded(_ level: Int) throws -> Raster {
        let gray = try grayscale()
        let cut = try level >= 0 ? level : gray.otsu() + 1
        return try gray.lookUp((0..<256).map { $0 >= cut ? 255 : 0 })
    }

    func otsu() throws -> Int {
        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        var source = buffer
        try require(vImageHistogramCalculation_Planar8(&source, &histogram, vImage_Flags(kvImageNoFlags)), "measure the histogram")
        let total = Double(histogram.reduce(0, +))
        let weighted = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * Double($1.element) }
        var background = 0.0
        var backgroundSum = 0.0
        var best = 0.0
        var level = 0
        for value in 0..<256 {
            background += Double(histogram[value])
            if background == 0 {
                continue
            }
            let foreground = total - background
            if foreground == 0 {
                break
            }
            backgroundSum += Double(value) * Double(histogram[value])
            let difference = backgroundSum / background - (weighted - backgroundSum) / foreground
            let between = background * foreground * difference * difference
            if between > best {
                best = between
                level = value
            }
        }
        return level
    }

    func masked(low: [UInt8], high: [UInt8]) throws -> Raster {
        if isGray {
            let lower = Int(low.max() ?? 0)
            let upper = Int(high.min() ?? 255)
            return try lookUp((0..<256).map { $0 >= lower && $0 <= upper ? 255 : 0 })
        }
        let flags = Raster(width: width, height: height, channels: 4)
        let table = { (channel: Int, flag: UInt8) -> [UInt8] in
            (0..<256).map { $0 >= Int(low[channel]) && $0 <= Int(high[channel]) ? flag : 0 }
        }
        let blue = table(2, 1)
        let green = table(1, 2)
        let red = table(0, 4)
        let alpha = [UInt8](repeating: 0, count: 256)
        var source = buffer
        var marked = flags.buffer
        try require(vImageTableLookUp_ARGB8888(&source, &marked, blue, green, red, alpha, vImage_Flags(kvImageNoFlags)), "mask the image")
        let sum = Raster(width: width, height: height, channels: 1)
        var summed = sum.buffer
        let matrix: [Int16] = [1, 1, 1, 0]
        try require(vImageMatrixMultiply_ARGB8888ToPlanar8(&marked, &summed, matrix, 1, nil, 0, vImage_Flags(kvImageNoFlags)), "mask the image")
        return try sum.lookUp((0..<256).map { $0 == 7 ? 255 : 0 })
    }

    func inverted() throws -> Raster {
        let flipped = (0..<256).map { UInt8(255 - $0) }
        if isGray {
            return try lookUp(flipped)
        }
        let out = Raster(width: width, height: height, channels: 4)
        let same = (0..<256).map { UInt8($0) }
        var source = buffer
        var destination = out.buffer
        try require(vImageTableLookUp_ARGB8888(&source, &destination, flipped, flipped, flipped, same, vImage_Flags(kvImageNoFlags)), "invert the image")
        return out
    }

    func morphed(radius: Int, dilate: Bool) throws -> Raster {
        let out = Raster(width: width, height: height, channels: channels)
        let size = vImagePixelCount(radius * 2 + 1)
        var source = buffer
        var destination = out.buffer
        let flags = vImage_Flags(kvImageNoFlags)
        let error = switch (isGray, dilate) {
        case (true, true): vImageMax_Planar8(&source, &destination, nil, 0, 0, size, size, flags)
        case (true, false): vImageMin_Planar8(&source, &destination, nil, 0, 0, size, size, flags)
        case (false, true): vImageMax_ARGB8888(&source, &destination, nil, 0, 0, size, size, flags)
        case (false, false): vImageMin_ARGB8888(&source, &destination, nil, 0, 0, size, size, flags)
        }
        try require(error, dilate ? "dilate the image" : "erode the image")
        return out
    }

    func pixel(x: Int, y: Int) -> [Int] {
        let pointer = row(y) + x * channels
        if isGray {
            return [Int(pointer[0]), Int(pointer[0]), Int(pointer[0]), 255]
        }
        return [Int(pointer[2]), Int(pointer[1]), Int(pointer[0]), Int(pointer[3])]
    }

    func planes() throws -> [Raster] {
        if isGray {
            return [self]
        }
        let planes = (0..<4).map { _ in Raster(width: width, height: height, channels: 1) }
        var source = buffer
        var blue = planes[0].buffer
        var green = planes[1].buffer
        var red = planes[2].buffer
        var alpha = planes[3].buffer
        try require(vImageConvert_ARGB8888toPlanar8(&source, &blue, &green, &red, &alpha, vImage_Flags(kvImageNoFlags)), "split the channels")
        return [planes[2], planes[1], planes[0], planes[3]]
    }

    func floats() -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                vDSP_vfltu8(row(y), 1, out.baseAddress! + y * width, 1, vDSP_Length(width))
            }
        }
        return values
    }

    func statistics() throws -> [String: [Double]] {
        var mean: [Double] = []
        var low: [Double] = []
        var high: [Double] = []
        var deviation: [Double] = []
        for plane in try planes() {
            let values = plane.floats()
            let count = vDSP_Length(values.count)
            var average: Float = 0
            var square: Float = 0
            var minimum: Float = 0
            var maximum: Float = 0
            vDSP_meanv(values, 1, &average, count)
            vDSP_measqv(values, 1, &square, count)
            vDSP_minv(values, 1, &minimum, count)
            vDSP_maxv(values, 1, &maximum, count)
            mean.append(rounded(Double(average)))
            low.append(Double(minimum))
            high.append(Double(maximum))
            deviation.append(rounded(Double(max(square - average * average, 0)).squareRoot()))
        }
        return ["mean": mean, "min": low, "max": high, "deviation": deviation]
    }

    func copied(into destination: Raster, x: Int, y: Int) {
        let columns = min(width, destination.width - x)
        guard columns > 0, channels == destination.channels else { return }
        for row in 0..<min(height, destination.height - y) {
            memcpy(destination.row(y + row) + x * channels, self.row(row), columns * channels)
        }
    }
}

nonisolated func require(_ error: vImage_Error, _ operation: String) throws {
    if error != kvImageNoError {
        throw GraphicsError("Error", "graphics: \(operation): vImage error \(error)")
    }
}
