import AVFoundation
import Vision
import CoreImage

final class VisionIdentity {
    private var positives: [VNFeaturePrintObservation] = []
    private var negatives: [VNFeaturePrintObservation] = []
    private var separation = 0.0
    private var lastLearnedAt = 0.0
    var ready: Bool { !positives.isEmpty && !negatives.isEmpty && separation > 0 }

    private func feature(_ buffer: CVPixelBuffer, rect: CGRect) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14.0, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
        else { request.revision = VNGenerateImageFeaturePrintRequestRevision1 }
        request.imageCropAndScaleOption = .scaleFit
        let image = CIImage(cvPixelBuffer: buffer)
        let crop = CGRect(x: rect.minX*image.extent.width, y: rect.minY*image.extent.height,
                          width: rect.width*image.extent.width, height: rect.height*image.extent.height)
        do {
            try VNImageRequestHandler(ciImage: image.cropped(to: crop), orientation: .up, options: [:]).perform([request])
            return request.results?.first
        } catch { return nil }
    }
    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double {
        var value: Float = .infinity
        do { try a.computeDistance(&value, to: b); return Double(value) }
        catch { return .infinity }
    }
    func reset() { positives = []; negatives = []; separation = 0; lastLearnedAt = 0 }
    func enroll(_ buffer: CVPixelBuffer, rect: CGRect) -> Bool {
        reset()
        guard let positive = feature(buffer, rect: rect) else { return false }
        positives = [positive]
        for y in [0.0, (1-rect.height)/2, 1-rect.height] {
            for x in [0.0, (1-rect.width)/2, 1-rect.width] {
                let candidate = CGRect(x:x,y:y,width:rect.width,height:rect.height)
                let intersection = candidate.intersection(rect)
                guard intersection.isNull || intersection.width*intersection.height < rect.width*rect.height*0.05 else { continue }
                if let negative = feature(buffer, rect: candidate) { negatives.append(negative) }
            }
        }
        separation = negatives.map { distance(positive,$0) }.min() ?? 0
        return ready && separation.isFinite
    }
    func accepts(_ buffer: CVPixelBuffer, rect: CGRect, learn: Bool = false, at time: Double = 0) -> Bool {
        guard ready, let candidate = feature(buffer, rect: rect) else { return false }
        let positiveDistance = positives.map { distance(candidate,$0) }.min() ?? .infinity
        let negativeDistance = negatives.map { distance(candidate,$0) }.min() ?? 0
        guard IdentityDecision.accepts(positive: positiveDistance, negative: negativeDistance, separation: separation) else { return false }
        if learn, time-lastLearnedAt > 1, positiveDistance > separation*0.12 {
            lastLearnedAt = time; positives.append(candidate)
            if positives.count > 6 { positives.remove(at: 1) }
        }
        return true
    }
}
