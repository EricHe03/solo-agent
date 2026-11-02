import CoreGraphics
import CoreML
import Foundation
import Vision

nonisolated final class RecognizedText: @unchecked Sendable {
    let lines: [[String: Any]]
    private let candidates: [[VNRecognizedText]]
    private let place: (CGPoint) -> CGPoint

    init(_ observations: [VNRecognizedTextObservation], place: @escaping (CGPoint) -> CGPoint) {
        let recognized = observations.compactMap { observation -> (VNRecognizedTextObservation, [VNRecognizedText])? in
            let candidates = observation.topCandidates(10)
            return candidates.isEmpty ? nil : (observation, candidates)
        }
        candidates = recognized.map(\.1)
        lines = recognized.map { observation, candidates in
            Recognition.shape(observation, place).merging([
                "text": candidates[0].string, "confidence": rounded(Double(candidates[0].confidence)),
                "candidates": candidates.map { ["text": $0.string, "confidence": rounded(Double($0.confidence))] },
            ]) { $1 }
        }
        self.place = place
    }

    func boundingBox(line: Int, candidate: Int, start: Int, end: Int) throws -> [String: Any]? {
        guard candidates.indices.contains(line), candidates[line].indices.contains(candidate) else { return nil }
        let recognized = candidates[line][candidate]
        let text = recognized.string
        guard start >= 0, start <= end, end <= text.utf16.count else { return nil }
        let range = String.Index(utf16Offset: start, in: text)..<String.Index(utf16Offset: end, in: text)
        return try recognized.boundingBox(for: range).map { Recognition.shape($0, place) }
    }
}

nonisolated enum Recognition {
    // The accurate recognizer stops reading CJK glyphs below about 20 px (Vision, iOS 27).
    private static let glyphPixels = 24.0

    static func restrict(_ request: VNRequest) {
        guard #available(iOS 17.0, macOS 14.0, *), let supported = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in supported {
            let engine = devices.first { device in
                if case .neuralEngine = device { return true }
                return false
            }
            let processor = devices.first { device in
                if case .cpu = device { return true }
                return false
            }
            if let chosen = engine ?? processor {
                request.setComputeDevice(chosen, for: stage)
            }
        }
    }

    static func warm() {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = deviceLanguages(request)
            restrict(request)
            if let image = try? Raster(width: 64, height: 32, channels: 4).cgImage() {
                try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            }
        }
    }

    static func deviceLanguages(_ request: VNRecognizeTextRequest) -> [String] {
        guard let supported = try? request.supportedRecognitionLanguages(), !supported.isEmpty else { return [] }
        var chosen: [String] = []
        for preferred in Locale.preferredLanguages + ["en-US"] {
            let language = Locale(identifier: preferred).language
            let match = supported.first { $0 == preferred }
                ?? supported.first { Locale(identifier: $0).language.languageCode == language.languageCode && Locale(identifier: $0).language.script == language.script }
                ?? supported.first { Locale(identifier: $0).language.languageCode == language.languageCode }
            if let match, !chosen.contains(match) {
                chosen.append(match)
            }
        }
        // Vision pairs Chinese with English only (Recognizing Text in Images, Apple Developer Documentation).
        if let chinese = chosen.first(where: { $0.hasPrefix("zh") }) {
            return chosen.contains("en-US") ? [chinese, "en-US"] : [chinese]
        }
        return chosen
    }

    static func shape(_ observation: VNRectangleObservation, _ place: (CGPoint) -> CGPoint) -> [String: Any] {
        let corners = [observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft].map(place)
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let frame = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return ["quad": corners.map(pointJSON), "frame": rectJSON(frame), "center": centerJSON(frame)]
    }

    static func text(_ node: ImageNode, _ arguments: Arguments, token: CancelToken) throws -> RecognizedText {
        var raster = try node.raster(token)
        var origin = CGPoint.zero
        if let region = arguments.rect("region") {
            let pixels = try node.pixelRect(space: region)
            raster = raster.view(x: Int(pixels.minX), y: Int(pixels.minY), width: Int(pixels.width), height: Int(pixels.height))
            origin = pixels.origin
        }
        try token.check()
        let request = VNRecognizeTextRequest()
        if let level = arguments.string("level") {
            request.recognitionLevel = level == "fast" ? .fast : .accurate
        }
        if let correction = arguments.bool("correction") {
            request.usesLanguageCorrection = correction
        }
        request.recognitionLanguages = arguments.strings("languages") ?? deviceLanguages(request)
        if let detect = arguments.bool("detectLanguage") {
            request.automaticallyDetectsLanguage = detect
        }
        if let words = arguments.strings("words") {
            request.customWords = words
        }
        var sampled = raster
        if let height = arguments.double("minimumHeight") {
            request.minimumTextHeight = Float(min(max(height * node.scale / Double(raster.height), 0), 1))
            let density = glyphPixels / height
            if density < node.scale {
                sampled = try raster.resized(width: max(Int(Double(raster.width) * density / node.scale), 1), height: max(Int(Double(raster.height) * density / node.scale), 1))
            }
        }
        restrict(request)
        try VNImageRequestHandler(cgImage: sampled.cgImage(), options: [:]).perform([request])
        try token.check()
        let width = Double(raster.width)
        let height = Double(raster.height)
        let transform = node.transform
        return RecognizedText(request.results ?? []) { point in
            CGPoint(x: origin.x + point.x * width, y: origin.y + (1 - point.y) * height).applying(transform)
        }
    }

    static func featurePrint(_ node: ImageNode, token: CancelToken) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        restrict(request)
        try VNImageRequestHandler(cgImage: node.raster(token).cgImage(), options: [:]).perform([request])
        guard let observation = request.results?.first else {
            throw GraphicsError("Error", "graphics: Vision made no feature print")
        }
        return observation
    }

    static func distance(_ reference: VNFeaturePrintObservation, _ other: ImageNode, token: CancelToken) throws -> Double {
        var distance: Float = 0
        try reference.computeDistance(&distance, to: featurePrint(other, token: token))
        return Double(distance)
    }

    static func barcodes(_ node: ImageNode, token: CancelToken) throws -> [[String: Any]] {
        let request = VNDetectBarcodesRequest()
        restrict(request)
        let raster = try node.raster(token)
        try VNImageRequestHandler(cgImage: raster.cgImage(), options: [:]).perform([request])
        let width = Double(raster.width)
        let height = Double(raster.height)
        let transform = node.transform
        let place = { (point: CGPoint) in CGPoint(x: point.x * width, y: (1 - point.y) * height).applying(transform) }
        return (request.results ?? []).map { observation in
            let symbology = observation.symbology.rawValue
            return shape(observation, place).merging([
                "payload": observation.payloadStringValue.map { $0 as Any } ?? NSNull(),
                "symbology": symbology.hasPrefix("VNBarcodeSymbology") ? String(symbology.dropFirst("VNBarcodeSymbology".count)) : symbology,
            ]) { $1 }
        }
    }
}
