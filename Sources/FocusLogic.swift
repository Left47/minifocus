import Foundation
import CoreGraphics

enum IdentityDecision {
    static func accepts(positive: Double, negative: Double, separation: Double) -> Bool {
        guard positive.isFinite, negative.isFinite, separation.isFinite, separation > 0 else { return false }
        // Relative distances avoid assuming the numeric scale of a Vision revision.
        return positive < separation*0.80 && positive < negative*0.72
    }
}

// The tracker must not consume deliberately blurred frames during acquisition.
struct AcquisitionGate {
    private(set) var isAcquiring = false
    private var readyAt = Double.infinity
    mutating func begin() { isAcquiring = true; readyAt = .infinity }
    mutating func finishSweep(at time: Double) { readyAt = time + 0.5 }
    mutating func cancel() { isAcquiring = false; readyAt = .infinity }
    mutating func releaseIfSettled(at time: Double) -> Bool {
        guard isAcquiring, time >= readyAt else { return false }
        cancel(); return true
    }
}

enum TargetGeometry {
    static func acceptable(_ next: CGRect, after previous: CGRect, confidence: Float) -> Bool {
        guard confidence >= 0.65, next.width >= 0.015, next.height >= 0.015,
              next.minX >= 0, next.minY >= 0, next.maxX <= 1, next.maxY <= 1 else { return false }
        let ratio = next.width * next.height / max(0.0001, previous.width * previous.height)
        let travel = hypot(next.midX - previous.midX, next.midY - previous.midY)
        return ratio > 0.55 && ratio < 1.8 && travel < max(0.08, hypot(previous.width, previous.height) * 0.6)
    }

    static func imageRect(in bounds: CGRect, width: Int, height: Int) -> CGRect {
        guard width > 0, height > 0 else { return bounds }
        let scale = min(bounds.width / Double(width), bounds.height / Double(height))
        let size = CGSize(width: Double(width) * scale, height: Double(height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}

enum FocusMetric {
    // Variance of the luminance Laplacian, sampled inside the target rather than
    // over the desk. Coordinates arriving from Vision have a lower-left origin.
    static func score(width: Int, height: Int, roi: CGRect, luma: (Int, Int) -> Double) -> Double {
        let inner = roi.insetBy(dx: roi.width * 0.12, dy: roi.height * 0.12)
        let x0 = max(1, Int(inner.minX * Double(width)))
        let x1 = min(width - 2, Int(inner.maxX * Double(width)))
        let y0 = max(1, Int((1 - inner.maxY) * Double(height)))
        let y1 = min(height - 2, Int((1 - inner.minY) * Double(height)))
        guard x1 > x0, y1 > y0 else { return 0 }
        let strideSize = max(1, max(x1 - x0, y1 - y0) / 140)
        var sum = 0.0, square = 0.0, count = 0.0
        for y in stride(from: y0, through: y1, by: strideSize) {
            for x in stride(from: x0, through: x1, by: strideSize) {
                let v = luma(x-1,y) + luma(x+1,y) + luma(x,y-1) + luma(x,y+1) - 4*luma(x,y)
                sum += v; square += v*v; count += 1
            }
        }
        return max(0, square / count - pow(sum / count, 2))
    }
}

final class FocusSweep {
    enum Event { case waiting, move(Int), finished(position: Int, score: Double) }
    private let minimum: Int, maximum: Int, step: Int, origin: Int
    private var candidates: [Int], index = 0, samples: [Double] = []
    private var scores: [Int: Double] = [:]
    private var readyAt: Double = 0
    private var refine: Bool
    private let exhaustive: Bool
    private var extending: Bool
    private var coarseStep: Int
    let settleTime: Double
    var target: Int { candidates[index] }

    init(current: Int, minimum: Int, maximum: Int, step: Int, wide: Bool, exhaustive: Bool = false, settleTime: Double = 0.18) {
        self.minimum = minimum; self.maximum = maximum; self.step = step; self.origin = current
        self.settleTime = settleTime; refine = wide; self.exhaustive = exhaustive; extending = wide && !exhaustive
        coarseStep = exhaustive ? max(step, ((maximum - minimum) / 10 / step) * step) : step * 4
        if wide && exhaustive {
            candidates = Array(Set([current, minimum, maximum] + Array(stride(from: minimum, through: maximum, by: coarseStep)))).sorted()
            // Measure current focus before deliberately blurring the picture.
            candidates.removeAll { $0 == current }; candidates.insert(current, at: 0)
        } else if wide {
            candidates = Array(Set([current, max(minimum, current-coarseStep), min(maximum, current+coarseStep)]))
            candidates.sort { abs($0-current) == abs($1-current) ? $0 < $1 : abs($0-current) < abs($1-current) }
        } else {
            candidates = [current, current-step*2, current-step, current+step, current+step*2].filter { $0 >= minimum && $0 <= maximum }
        }
    }
    func didMove(at time: Double) { readyAt = time + settleTime; samples = [] }
    func add(score: Double, at time: Double) -> Event {
        guard time >= readyAt, score.isFinite else { return .waiting }
        samples.append(score)
        guard samples.count >= 3 else { return .waiting }
        scores[target] = samples.sorted()[1]
        if index + 1 < candidates.count { index += 1; samples = []; return .move(target) }
        let best = scores.max { lhs, rhs in
            if lhs.value == rhs.value { return abs(lhs.key-origin) > abs(rhs.key-origin) }
            return lhs.value < rhs.value
        }!
        if extending {
            let lo = scores.keys.min()!, hi = scores.keys.max()!
            let next: Int?
            if best.key == lo && lo > minimum { next = max(minimum, lo-coarseStep) }
            else if best.key == hi && hi < maximum { next = min(maximum, hi+coarseStep) }
            else { next = nil }
            if let next = next { candidates = [next]; index = 0; samples = []; return .move(next) }
            extending = false
        }
        if refine {
            refine = false
            candidates = Array(stride(from: max(minimum, best.key-coarseStep), through: min(maximum, best.key+coarseStep), by: step)).filter { scores[$0] == nil }
            if !candidates.isEmpty { index = 0; samples = []; return .move(target) }
        }
        // Avoid moving the lens for noise or tiny differences on a stationary mini.
        let baseline = scores[origin] ?? 0
        let chosen = best.value > baseline * 1.08 ? best.key : origin
        return .finished(position: chosen, score: scores[chosen] ?? best.value)
    }
}
