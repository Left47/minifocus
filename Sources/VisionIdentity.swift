import AVFoundation
import Vision
import CoreImage

final class VisionIdentity {
    private let diagnostic: Bool
    init(diagnostic: Bool = false) { self.diagnostic = diagnostic }
    private var positives: [VNFeaturePrintObservation] = []
    private var negatives: [VNFeaturePrintObservation] = []
    private var separation = 0.0
    private var lastLearnedAt = 0.0
    private var referenceCount = 0
    var ready: Bool { !positives.isEmpty && !negatives.isEmpty && separation > 0 }

    private func feature(_ buffer: CVPixelBuffer, rect: CGRect, degrees: Int = 0) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        if #available(macOS 14.0, *) { request.revision = VNGenerateImageFeaturePrintRequestRevision2 }
        else { request.revision = VNGenerateImageFeaturePrintRequestRevision1 }
        request.imageCropAndScaleOption = .scaleFit
        let image = CIImage(cvPixelBuffer: buffer)
        let crop = CGRect(x: rect.minX*image.extent.width, y: rect.minY*image.extent.height,
                          width: rect.width*image.extent.width, height: rect.height*image.extent.height)
        do {
            let cropped = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            let rotated = cropped.transformed(by: CGAffineTransform(rotationAngle: Double(degrees)*Double.pi/180))
            try VNImageRequestHandler(ciImage: rotated, orientation: .up, options: [:]).perform([request])
            return request.results?.first
        } catch { return nil }
    }
    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Double {
        var value: Float = .infinity
        do { try a.computeDistance(&value, to: b); return Double(value) }
        catch { return .infinity }
    }
    func reset() { positives = []; negatives = []; separation = 0; lastLearnedAt = 0; referenceCount = 0 }
    func enroll(_ buffer: CVPixelBuffer, rect: CGRect) -> Bool {
        reset()
        guard let positive = feature(buffer, rect: rect) else { return false }
        positives = [positive]
        // Keep the miniature's identity at every roll angle, rather than asking
        // an upright image embedding to recognize an upside-down object.
        positives += stride(from: 15, to: 360, by: 15).compactMap { feature(buffer, rect: rect, degrees: $0) }
        referenceCount = positives.count
        for y in [0.0, (1-rect.height)/2, 1-rect.height] {
            for x in [0.0, (1-rect.width)/2, 1-rect.width] {
                let candidate = CGRect(x:x,y:y,width:rect.width,height:rect.height)
                let intersection = candidate.intersection(rect)
                guard intersection.isNull || intersection.width*intersection.height < rect.width*rect.height*0.05 else { continue }
                if let negative = feature(buffer, rect: candidate) { negatives.append(negative) }
            }
        }
        separation = positives.flatMap { p in negatives.map { distance(p,$0) } }.min() ?? 0
        if diagnostic { print("Identity references=\(positives.count), separation=\(separation)") }
        return ready && separation.isFinite
    }
    func accepts(_ buffer: CVPixelBuffer, rect: CGRect, learn: Bool = false, at time: Double = 0) -> Bool {
        guard ready, let candidate = feature(buffer, rect: rect) else { return false }
        let positiveDistance = positives.map { distance(candidate,$0) }.min() ?? .infinity
        let negativeDistance = negatives.map { distance(candidate,$0) }.min() ?? 0
        guard IdentityDecision.accepts(positive: positiveDistance, negative: negativeDistance, separation: separation) else {
            if diagnostic { print("Rejected identity: positive=\(positiveDistance), negative=\(negativeDistance), separation=\(separation)") }
            return false
        }
        if learn, time-lastLearnedAt > 1, positiveDistance > separation*0.12 {
            lastLearnedAt = time; positives.append(candidate)
            positives += [90,180,270].compactMap { feature(buffer, rect: rect, degrees: $0) }
            while positives.count > referenceCount+24 { positives.remove(at: referenceCount) }
        }
        return true
    }
}
