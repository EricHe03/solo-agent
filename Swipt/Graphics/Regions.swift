import Accelerate
import CoreGraphics
import Foundation

nonisolated struct Component {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var count: Int
    var sumX: Double
    var sumY: Double

    var rect: CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    var centroid: CGPoint {
        CGPoint(x: sumX / Double(count) + 0.5, y: sumY / Double(count) + 0.5)
    }
}

nonisolated enum Regions {
    static let largestCount = 10_000

    static func binarized(_ raster: Raster) throws -> Raster {
        try raster.lookUp((0..<256).map { $0 >= 128 ? 255 : 0 })
    }

    static func components(_ binary: Raster, minimumPixels: Int, token: CancelToken?) throws -> [Component] {
        struct Run {
            var start: Int
            var end: Int
            var label: Int
        }
        var parents: [Int] = []
        func root(_ label: Int) -> Int {
            var current = label
            while parents[current] != current {
                parents[current] = parents[parents[current]]
                current = parents[current]
            }
            return current
        }
        func join(_ a: Int, _ b: Int) {
            let first = root(a)
            let second = root(b)
            if first != second {
                parents[max(first, second)] = min(first, second)
            }
        }
        var all: [(y: Int, run: Run)] = []
        var previous: [Run] = []
        let width = binary.width
        for y in 0..<binary.height {
            if y % 256 == 0 {
                try token?.check()
            }
            let row = UnsafeRawPointer(binary.row(y))
            var current: [Run] = []
            var x = 0
            while x < width, let found = memchr(row + x, 255, width - x) {
                let start = row.distance(to: UnsafeRawPointer(found))
                let rest = memchr(row + start, 0, width - start)
                let end = rest.map { row.distance(to: UnsafeRawPointer($0)) - 1 } ?? width - 1
                parents.append(parents.count)
                current.append(Run(start: start, end: end, label: parents.count - 1))
                x = end + 1
            }
            var above = 0
            for run in current {
                while above < previous.count, previous[above].end < run.start - 1 {
                    above += 1
                }
                var index = above
                while index < previous.count, previous[index].start <= run.end + 1 {
                    join(run.label, previous[index].label)
                    index += 1
                }
            }
            all += current.map { (y: y, run: $0) }
            previous = current
        }
        var merged: [Int: Component] = [:]
        for (y, run) in all {
            let label = root(run.label)
            let count = run.end - run.start + 1
            let sumX = Double(count) * Double(run.start + run.end) / 2
            if var component = merged[label] {
                component.minX = min(component.minX, run.start)
                component.maxX = max(component.maxX, run.end)
                component.minY = min(component.minY, y)
                component.maxY = max(component.maxY, y)
                component.count += count
                component.sumX += sumX
                component.sumY += Double(count * y)
                merged[label] = component
            } else {
                merged[label] = Component(minX: run.start, minY: y, maxX: run.end, maxY: y, count: count, sumX: sumX, sumY: Double(count * y))
            }
        }
        let kept = merged.values.filter { $0.count >= minimumPixels }.sorted { $0.minY != $1.minY ? $0.minY < $1.minY : $0.minX < $1.minX }
        return Array(kept.prefix(largestCount))
    }

    static func difference(_ first: Raster, _ second: Raster, threshold: Int) throws -> (mask: Raster, changed: Int) {
        let a = try first.grayscale()
        let b = try second.grayscale()
        let width = a.width
        let mask = Raster(width: width, height: a.height, channels: 1)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: width)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: width)
        defer {
            left.deallocate()
            right.deallocate()
        }
        var cut = Float(threshold) - 0.5
        var half: Float = 127.5
        var changed: Float = 0
        let count = vDSP_Length(width)
        for y in 0..<a.height {
            vDSP_vfltu8(a.row(y), 1, left, 1, count)
            vDSP_vfltu8(b.row(y), 1, right, 1, count)
            vDSP_vsub(right, 1, left, 1, left, 1, count)
            vDSP_vabs(left, 1, left, 1, count)
            vDSP_vthrsc(left, 1, &cut, &half, left, 1, count)
            vDSP_vsadd(left, 1, &half, left, 1, count)
            var sum: Float = 0
            vDSP_sve(left, 1, &sum, count)
            changed += sum
            vDSP_vfixu8(left, 1, mask.row(y), 1, count)
        }
        return (mask, Int((changed / 255).rounded()))
    }

    static func regions(_ mask: Raster, merge radius: Int, token: CancelToken?) throws -> [CGRect] {
        let merged = try radius > 0 ? mask.morphed(radius: radius, dilate: true) : mask
        return try components(merged, minimumPixels: 1, token: token).map { component in
            let rect = component.rect
            let width = max(rect.width - CGFloat(radius * 2), 1)
            let height = max(rect.height - CGFloat(radius * 2), 1)
            return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        }
    }

    static func minimumChange(_ total: Int) -> Int {
        max(4, total / 5000)
    }
}

nonisolated final class ChangeTracker {
    struct Change {
        var before: Double
        var start: Double
        var after: Double
        var regions: [CGRect]
        var width: Int
        var height: Int
    }

    let threshold = 24
    let settle: Double = 300
    private(set) var changes: [Change] = []
    private var reference: Raster?
    private var last: Raster?
    private var lastTime: Double = 0
    private var start: Double?
    private var before: Double = 0
    private var motion: Double = 0

    private func changed(_ a: Raster, _ b: Raster) throws -> Bool {
        guard a.width == b.width, a.height == b.height else { return true }
        return try Regions.difference(a, b, threshold: threshold).changed >= Regions.minimumChange(a.width * a.height)
    }

    func push(_ plane: Raster, time: Double) throws {
        defer {
            last = plane
            lastTime = time
        }
        guard let reference, let last else {
            reference = plane
            return
        }
        if start != nil {
            if try changed(last, plane) {
                motion = time
            } else if time - motion >= settle {
                try close()
            }
        } else if try changed(reference, plane) {
            start = time
            before = lastTime
            motion = time
        }
    }

    func tick(_ now: Double) throws {
        if start != nil, now - motion >= settle {
            try close()
        }
    }

    func finish() throws {
        if start != nil {
            try close()
        }
    }

    private func close() throws {
        guard let start, let reference, let last else { return }
        self.start = nil
        self.reference = last
        if reference.width != last.width || reference.height != last.height {
            changes.append(Change(before: before, start: start, after: motion, regions: [CGRect(x: 0, y: 0, width: last.width, height: last.height)], width: last.width, height: last.height))
            return
        }
        let difference = try Regions.difference(reference, last, threshold: threshold)
        guard difference.changed >= Regions.minimumChange(last.width * last.height) else { return }
        let regions = try Regions.regions(difference.mask, merge: 2, token: nil)
        changes.append(Change(before: before, start: start, after: motion, regions: regions, width: last.width, height: last.height))
    }
}
