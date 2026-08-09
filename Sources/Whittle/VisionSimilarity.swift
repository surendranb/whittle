import CoreGraphics
import Vision

/// Computes Apple Vision feature prints and distances between them.
/// Smaller distance = more visually similar.
enum VisionSimilarity {

    static func featurePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        } catch {
            return nil
        }
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double? {
        var d: Float = 0
        do {
            try a.computeDistance(&d, to: b)
            return Double(d)
        } catch {
            return nil
        }
    }
}
