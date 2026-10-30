import Accelerate
import CoreGraphics
import Foundation

nonisolated enum TemplateMatching {
    struct Match {
        var rect: CGRect
        var score: Double
        var scale: Double
    }

    private struct Plane {
        var width: Int
        var height: Int
        var values: [Float]
    }

    private struct Kernel {
        var width: Int
        var height: Int
        var centered: [Float]
        var weights: [Float]
        var weightSum: Float
        var variance: Float
    }

    private struct Level {
        var image: Plane
        var squared: [Float]
        var kernel: Kernel
    }

    private static let coarsestSide = 8
    private static let deepestLevel = 5
    private static let radius = 2

    static func find(target: Raster, template: Raster, factors: [Double], threshold: Double, limit: Int, overlap: Double, token: CancelToken) throws -> [Match] {
        let base = try plane(target)
        var found: [Match] = []
        for factor in factors {
            let width = Int((Double(template.width) * factor).rounded())
            let height = Int((Double(template.height) * factor).rounded())
            guard width >= 3, height >= 3, width <= target.width, height <= target.height else { continue }
            let resized = try template.resized(width: width, height: height)
            found += try search(base, target: target, template: resized, threshold: Float(threshold), limit: limit, factor: factor, token: token)
        }
        return suppress(found.sorted { $0.score > $1.score }, overlap: overlap, limit: limit)
    }

    private static func plane(_ raster: Raster) throws -> Plane {
        var values = try raster.grayscale().floats()
        var scale: Float = 1 / 255
        values.withUnsafeMutableBufferPointer { pointer in
            vDSP_vsmul(pointer.baseAddress!, 1, &scale, pointer.baseAddress!, 1, vDSP_Length(pointer.count))
        }
        return Plane(width: raster.width, height: raster.height, values: values)
    }

    private static func weights(_ template: Raster) throws -> Plane {
        guard !template.isGray else {
            return Plane(width: template.width, height: template.height, values: [Float](repeating: 1, count: template.width * template.height))
        }
        return try plane(template.planes()[3])
    }

    private static func scaled(_ plane: Plane, width: Int, height: Int) throws -> Plane {
        var out = [Float](repeating: 0, count: width * height)
        var values = plane.values
        try values.withUnsafeMutableBufferPointer { source in
            try out.withUnsafeMutableBufferPointer { destination in
                var input = vImage_Buffer(data: source.baseAddress!, height: vImagePixelCount(plane.height), width: vImagePixelCount(plane.width), rowBytes: plane.width * 4)
                var output = vImage_Buffer(data: destination.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                try require(vImageScale_PlanarF(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling)), "scale the plane")
            }
        }
        return Plane(width: width, height: height, values: out)
    }

    private static func kernel(_ values: Plane, _ weights: Plane) throws -> Kernel {
        let count = vDSP_Length(values.values.count)
        var weightSum: Float = 0
        vDSP_sve(weights.values, 1, &weightSum, count)
        guard weightSum > 0.5 else {
            throw GraphicsError.range("the template is transparent")
        }
        var weighted = [Float](repeating: 0, count: values.values.count)
        vDSP_vmul(values.values, 1, weights.values, 1, &weighted, 1, count)
        var total: Float = 0
        vDSP_sve(weighted, 1, &total, count)
        var negativeMean = -total / weightSum
        var difference = [Float](repeating: 0, count: values.values.count)
        vDSP_vsadd(values.values, 1, &negativeMean, &difference, 1, count)
        var centered = [Float](repeating: 0, count: values.values.count)
        vDSP_vmul(difference, 1, weights.values, 1, &centered, 1, count)
        var variance: Float = 0
        vDSP_dotpr(centered, 1, difference, 1, &variance, count)
        return Kernel(width: values.width, height: values.height, centered: centered, weights: weights.values, weightSum: weightSum, variance: variance)
    }

    private static func squares(_ plane: Plane) -> [Float] {
        var out = [Float](repeating: 0, count: plane.values.count)
        vDSP_vsq(plane.values, 1, &out, 1, vDSP_Length(out.count))
        return out
    }

    private static func correlate(_ image: [Float], width: Int, height: Int, kernel: [Float], kernelWidth: Int, kernelHeight: Int) -> [Float] {
        let rows = height - kernelHeight + 1
        var total = [Float](repeating: 0, count: rows * width)
        var row = [Float](repeating: 0, count: rows * width)
        let length = vDSP_Length(rows * width - (kernelWidth - 1))
        image.withUnsafeBufferPointer { source in
            kernel.withUnsafeBufferPointer { filter in
                total.withUnsafeMutableBufferPointer { sum in
                    row.withUnsafeMutableBufferPointer { part in
                        for line in 0..<kernelHeight {
                            vDSP_conv(source.baseAddress! + line * width, 1, filter.baseAddress! + line * kernelWidth, 1, part.baseAddress!, 1, length, vDSP_Length(kernelWidth))
                            vDSP_vadd(sum.baseAddress!, 1, part.baseAddress!, 1, sum.baseAddress!, 1, length)
                        }
                    }
                }
            }
        }
        return total
    }

    private static func flat(_ kernel: Kernel) -> Float {
        1.6e-5 * kernel.weightSum
    }

    private static func score(_ level: Level, x: Int, y: Int) -> Float {
        let kernel = level.kernel
        let width = level.image.width
        var correlation: Float = 0
        var sum: Float = 0
        var square: Float = 0
        level.image.values.withUnsafeBufferPointer { image in
            level.squared.withUnsafeBufferPointer { squared in
                kernel.centered.withUnsafeBufferPointer { centered in
                    kernel.weights.withUnsafeBufferPointer { weights in
                        for line in 0..<kernel.height {
                            let offset = (y + line) * width + x
                            let template = line * kernel.width
                            var part: Float = 0
                            let count = vDSP_Length(kernel.width)
                            vDSP_dotpr(image.baseAddress! + offset, 1, centered.baseAddress! + template, 1, &part, count)
                            correlation += part
                            vDSP_dotpr(image.baseAddress! + offset, 1, weights.baseAddress! + template, 1, &part, count)
                            sum += part
                            vDSP_dotpr(squared.baseAddress! + offset, 1, weights.baseAddress! + template, 1, &part, count)
                            square += part
                        }
                    }
                }
            }
        }
        let variance = square - sum * sum / kernel.weightSum
        guard variance > flat(kernel), kernel.variance > 0 else { return 0 }
        return correlation / (kernel.variance * variance).squareRoot()
    }

    private static func search(_ base: Plane, target: Raster, template: Raster, threshold: Float, limit: Int, factor: Double, token: CancelToken) throws -> [Match] {
        let gray = try plane(template)
        let alpha = try weights(template)
        let full = try kernel(gray, alpha)
        guard full.variance / full.weightSum > 1e-6 else {
            throw GraphicsError.range("the template has no contrast to match")
        }
        var depth = 0
        while depth < deepestLevel, min(template.width, template.height) >> (depth + 1) >= coarsestSide {
            depth += 1
        }
        var levels: [Level] = [Level(image: base, squared: squares(base), kernel: full)]
        for level in stride(from: 1, through: depth, by: 1) {
            try token.check()
            let shrunkImage = try scaled(base, width: max(base.width >> level, 1), height: max(base.height >> level, 1))
            let width = max(template.width >> level, 1)
            let height = max(template.height >> level, 1)
            guard width <= shrunkImage.width, height <= shrunkImage.height else { break }
            let shrunk = try kernel(scaled(gray, width: width, height: height), scaled(alpha, width: width, height: height))
            levels.append(Level(image: shrunkImage, squared: squares(shrunkImage), kernel: shrunk))
        }
        let coarse = levels[levels.count - 1]
        let coarseKernel = coarse.kernel
        let image = coarse.image
        let rows = image.height - coarseKernel.height + 1
        let columns = image.width - coarseKernel.width + 1
        guard rows > 0, columns > 0 else { return [] }
        try token.check()
        let correlation = correlate(image.values, width: image.width, height: image.height, kernel: coarseKernel.centered, kernelWidth: coarseKernel.width, kernelHeight: coarseKernel.height)
        let sums = correlate(image.values, width: image.width, height: image.height, kernel: coarseKernel.weights, kernelWidth: coarseKernel.width, kernelHeight: coarseKernel.height)
        let squaredSums = correlate(coarse.squared, width: image.width, height: image.height, kernel: coarseKernel.weights, kernelWidth: coarseKernel.width, kernelHeight: coarseKernel.height)
        try token.check()
        let cutoff = max(threshold - (levels.count > 1 ? 0.25 : 0.1), 0)
        let minimum = flat(coarseKernel)
        var candidates: [(score: Float, x: Int, y: Int)] = []
        for y in 0..<rows {
            for x in 0..<columns {
                let index = y * image.width + x
                let variance = squaredSums[index] - sums[index] * sums[index] / coarseKernel.weightSum
                guard variance > minimum else { continue }
                let value = correlation[index] / (coarseKernel.variance * variance).squareRoot()
                if value >= cutoff {
                    candidates.append((value, x, y))
                }
            }
        }
        candidates.sort { $0.score > $1.score }
        var kept: [(x: Int, y: Int)] = []
        let wanted = min(max(limit * 3, 20), 300)
        for candidate in candidates {
            if kept.count >= wanted {
                break
            }
            if kept.contains(where: { abs($0.x - candidate.x) * 2 < coarseKernel.width && abs($0.y - candidate.y) * 2 < coarseKernel.height }) {
                continue
            }
            kept.append((candidate.x, candidate.y))
        }
        let colors: ColorKernel? = try !target.isGray && !template.isGray ? ColorKernel(template, alpha: alpha) : nil
        var matches: [Match] = []
        for candidate in kept {
            try token.check()
            var x = candidate.x
            var y = candidate.y
            var best: Float = 0
            for level in stride(from: levels.count - 2, through: 0, by: -1) {
                let current = levels[level]
                let limitX = current.image.width - current.kernel.width
                let limitY = current.image.height - current.kernel.height
                let centerX = x * 2
                let centerY = y * 2
                best = -2
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let px = min(max(centerX + dx, 0), limitX)
                        let py = min(max(centerY + dy, 0), limitY)
                        let value = score(current, x: px, y: py)
                        if value > best {
                            best = value
                            x = px
                            y = py
                        }
                    }
                }
            }
            if levels.count == 1 {
                best = score(levels[0], x: x, y: y)
            }
            let result = colors.map { $0.score(target, x: x, y: y) } ?? best
            if result >= threshold {
                matches.append(Match(rect: CGRect(x: x, y: y, width: template.width, height: template.height), score: Double(result), scale: factor))
            }
        }
        return matches
    }

    private struct ColorKernel {
        var width: Int
        var height: Int
        var centered: [[Float]]
        var weights: [Float]
        var weightSum: Float
        var variance: Float

        init(_ template: Raster, alpha: Plane) throws {
            width = template.width
            height = template.height
            weights = alpha.values
            let planes = try template.planes()
            var centered: [[Float]] = []
            var variance: Float = 0
            var weightSum: Float = 0
            vDSP_sve(alpha.values, 1, &weightSum, vDSP_Length(alpha.values.count))
            for channel in [2, 1, 0] {
                let plane = try TemplateMatching.kernel(TemplateMatching.plane(planes[channel]), alpha)
                centered.append(plane.centered)
                variance += plane.variance
            }
            self.centered = centered
            self.weightSum = weightSum
            self.variance = variance
        }

        func score(_ target: Raster, x: Int, y: Int) -> Float {
            var correlation: Float = 0
            var spread: Float = 0
            var scale: Float = 1 / 255
            let count = vDSP_Length(width)
            let values = UnsafeMutablePointer<Float>.allocate(capacity: width)
            defer { values.deallocate() }
            for channel in 0..<3 {
                var sum: Float = 0
                var square: Float = 0
                centered[channel].withUnsafeBufferPointer { kernel in
                    weights.withUnsafeBufferPointer { weights in
                        for line in 0..<height {
                            vDSP_vfltu8(target.row(y + line) + x * 4 + channel, 4, values, 1, count)
                            vDSP_vsmul(values, 1, &scale, values, 1, count)
                            var part: Float = 0
                            vDSP_dotpr(values, 1, kernel.baseAddress! + line * width, 1, &part, count)
                            correlation += part
                            vDSP_dotpr(values, 1, weights.baseAddress! + line * width, 1, &part, count)
                            sum += part
                            vDSP_vsq(values, 1, values, 1, count)
                            vDSP_dotpr(values, 1, weights.baseAddress! + line * width, 1, &part, count)
                            square += part
                        }
                    }
                }
                spread += max(square - sum * sum / weightSum, 0)
            }
            guard spread > 1.6e-5 * weightSum * 3, variance > 0 else { return 0 }
            return correlation / (variance * spread).squareRoot()
        }
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let shared = Double(overlap.width * overlap.height)
        return shared / (Double(a.width * a.height) + Double(b.width * b.height) - shared)
    }

    private static func suppress(_ sorted: [Match], overlap: Double, limit: Int) -> [Match] {
        var kept: [Match] = []
        for match in sorted {
            if kept.count >= limit {
                break
            }
            if kept.contains(where: { intersectionOverUnion($0.rect, match.rect) > overlap }) {
                continue
            }
            kept.append(match)
        }
        return kept
    }
}
