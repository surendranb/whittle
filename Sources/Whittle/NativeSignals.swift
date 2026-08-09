import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Fast, deterministic per-photo quality signals computed with Apple
/// frameworks — all on-device, milliseconds per photo at scan resolution.
/// Injected into the judge prompt as measured facts so the model ranks and
/// explains instead of squinting at thumbnails; this is what lets a small
/// local model do a big model's job.
struct NativeSignals {
    let sharpness: Double         // 0–1 relative edge energy (comparable within a burst)
    let faceCount: Int
    let faceQuality: Double?      // best VNFaceCaptureQuality across faces (0–1)
    let eyesClosedFaces: Int?     // faces with both eyes closed (CIDetector)
    let smilingFaces: Int?
    let maxFaceYawDegrees: Double?
    let horizonTiltDegrees: Double?
    let sceneLabel: String?       // top VNClassifyImageRequest label
    let aestheticScore: Double?   // -1…1, macOS 15+
    let isUtilityImage: Bool?     // screenshots/receipts/docs, macOS 15+

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func compute(for cgImage: CGImage) -> NativeSignals {
        // One handler, one pass for all Vision requests.
        let faceQualityRequest = VNDetectFaceCaptureQualityRequest()
        let faceRectsRequest = VNDetectFaceRectanglesRequest()
        let horizonRequest = VNDetectHorizonRequest()
        let classifyRequest = VNClassifyImageRequest()
        var requests: [VNRequest] = [faceQualityRequest, faceRectsRequest,
                                     horizonRequest, classifyRequest]

        var aestheticsRequest: VNRequest?
        if #available(macOS 15.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            aestheticsRequest = request
            requests.append(request)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform(requests)

        let faces = faceRectsRequest.results ?? []
        let qualities = (faceQualityRequest.results ?? [])
            .compactMap { $0.faceCaptureQuality.map(Double.init) }
        let yaws = faces.compactMap { $0.yaw?.doubleValue }
            .map { abs($0) * 180 / .pi }

        var tilt: Double?
        if let horizon = horizonRequest.results?.first {
            tilt = Double(horizon.angle) * 180 / .pi
        }

        var scene: String?
        if let top = (classifyRequest.results ?? [])
            .filter({ $0.confidence > 0.3 })
            .max(by: { $0.confidence < $1.confidence }) {
            scene = top.identifier.replacingOccurrences(of: "_", with: " ")
        }

        var aesthetic: Double?
        var utility: Bool?
        if #available(macOS 15.0, *),
           let observation = (aestheticsRequest as? VNCalculateImageAestheticsScoresRequest)?
               .results?.first {
            aesthetic = Double(observation.overallScore)
            utility = observation.isUtility
        }

        let (blinks, smiles) = faces.isEmpty ? (nil, nil) : blinkAndSmile(cgImage)

        return NativeSignals(
            sharpness: edgeEnergy(cgImage) ?? 0,
            faceCount: faces.count,
            faceQuality: qualities.max(),
            eyesClosedFaces: blinks,
            smilingFaces: smiles,
            maxFaceYawDegrees: yaws.max(),
            horizonTiltDegrees: tilt,
            sceneLabel: scene,
            aestheticScore: aesthetic,
            isUtilityImage: utility
        )
    }

    /// Eyes-closed and smile counts via CIDetector — old API, but the only
    /// cheap direct blink/smile signal Apple ships.
    private static func blinkAndSmile(_ cgImage: CGImage) -> (Int?, Int?) {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeFace, context: ciContext,
            options: [CIDetectorAccuracy: CIDetectorAccuracyLow]) else { return (nil, nil) }
        let features = detector.features(
            in: CIImage(cgImage: cgImage),
            options: [CIDetectorEyeBlink: true, CIDetectorSmile: true])
        let faces = features.compactMap { $0 as? CIFaceFeature }
        guard !faces.isEmpty else { return (0, 0) }
        let blinks = faces.filter { $0.leftEyeClosed && $0.rightEyeClosed }.count
        let smiles = faces.filter(\.hasSmile).count
        return (blinks, smiles)
    }

    /// Mean edge magnitude via CIEdges + area average — a cheap Laplacian-style
    /// focus measure. Comparable *within* a burst (same scene), which is the
    /// only comparison we ask of it.
    private static func edgeEnergy(_ cgImage: CGImage) -> Double? {
        let input = CIImage(cgImage: cgImage)
        let edges = CIFilter.edges()
        edges.inputImage = input
        edges.intensity = 1
        guard let edged = edges.outputImage else { return nil }

        let average = CIFilter.areaAverage()
        average.inputImage = edged
        average.extent = input.extent
        guard let out = average.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &pixel, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        let lum = 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
        return lum / 255.0
    }

    /// One line per photo for the judge prompt, sharpness normalized against
    /// the burst's best. Only fields that exist are mentioned.
    static func promptBlock(_ signals: [NativeSignals]) -> String {
        guard !signals.isEmpty else { return "" }
        let maxSharp = max(signals.map(\.sharpness).max() ?? 1, 0.0001)

        // The burst's scene type, when the photos agree on one.
        var sceneLine = ""
        let labels = signals.compactMap(\.sceneLabel)
        if let first = labels.first, labels.count == signals.count,
           Set(labels).count == 1 {
            sceneLine = "\nScene type (measured): \(first)."
        }

        let lines = signals.enumerated().map { i, s -> String in
            var parts: [String] = [
                String(format: "relative sharpness %.2f (1.00 = sharpest of burst)",
                       s.sharpness / maxSharp)
            ]
            if let a = s.aestheticScore {
                parts.append(String(format: "aesthetic score %.2f (-1 to 1)", a))
            }
            if let t = s.horizonTiltDegrees, abs(t) > 0.2 {
                parts.append(String(format: "horizon tilted %.1f°", abs(t)))
            }
            if s.faceCount > 0 {
                var face = "\(s.faceCount) face(s)"
                if let q = s.faceQuality {
                    face += String(format: ", best face quality %.2f", q)
                }
                if let blinks = s.eyesClosedFaces, blinks > 0 {
                    face += ", \(blinks) with eyes closed"
                }
                if let smiles = s.smilingFaces {
                    face += ", \(smiles) smiling"
                }
                if let yaw = s.maxFaceYawDegrees, yaw > 20 {
                    face += String(format: ", a face turned %.0f° away", yaw)
                }
                parts.append(face)
            } else {
                parts.append("no faces")
            }
            if s.isUtilityImage == true {
                parts.append("utility image (screenshot/document)")
            }
            return "Photo \(i + 1): " + parts.joined(separator: ", ") + "."
        }
        return """

        Measured analysis (from on-device image processing — trust these numbers \
        over your own low-resolution impression; still judge composition and \
        expressions visually):\(sceneLine)
        \(lines.joined(separator: "\n"))
        """
    }
}
