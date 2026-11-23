import Foundation
import CoreGraphics

struct TargetAppearance {
    let luminance: [Double]
    let histogram: [Double]
    func match(_ other: TargetAppearance) -> (score: Double, color: Double, correlation: Double) {
        let color = zip(histogram, other.histogram).reduce(0) { $0 + sqrt($1.0 * $1.1) }
        let a = luminance.reduce(0,+) / Double(luminance.count), b = other.luminance.reduce(0,+) / Double(other.luminance.count)
        var dot = 0.0, aa = 0.0, bb = 0.0
        for i in luminance.indices {
            let x = luminance[i]-a, y = other.luminance[i]-b
            dot += x*y; aa += x*x; bb += y*y
        }
        let correlation = aa > 1 && bb > 1 ? dot / sqrt(aa*bb) : 0
        return (0.55 * color + 0.45 * max(0, correlation), color, correlation)
    }
}

struct AppearanceFrame {
    let width: Int, height: Int
    let rgb: [UInt8]
    func signature(_ rectangle: CGRect) -> TargetAppearance {
        var luminance = [Double](); luminance.reserveCapacity(144)
        var histogram = [Double](repeating: 0, count: 16)
        // Use an inset to reduce contamination from fingers and nearby faces.
        let rect = rectangle.insetBy(dx: rectangle.width*0.08, dy: rectangle.height*0.08)
        for y in 0..<12 {
            for x in 0..<12 {
                let px = min(width-1, max(0, Int((rect.minX + (Double(x)+0.5)/12*rect.width)*Double(width))))
                let py = min(height-1, max(0, Int((1-rect.maxY + (Double(y)+0.5)/12*rect.height)*Double(height))))
                let i = (py*width+px)*3
                let r = Double(rgb[i])/255, g = Double(rgb[i+1])/255, b = Double(rgb[i+2])/255
                let high = max(r,g,b), low = min(r,g,b), delta = high-low
                let luma = 0.2126*r + 0.7152*g + 0.0722*b
                luminance.append(luma*255)
                let bin: Int
                if high < 0.08 || delta / max(high, 0.001) < 0.22 {
                    bin = 12 + min(3, Int(luma*4))
                } else {
                    var hue: Double
                    if high == r { hue = (g-b)/delta }
                    else if high == g { hue = 2+(b-r)/delta }
                    else { hue = 4+(r-g)/delta }
                    if hue < 0 { hue += 6 }
                    bin = min(11, Int(hue*2))
                }
                histogram[bin] += 1.0/144
            }
        }
        return TargetAppearance(luminance: luminance, histogram: histogram)
    }
    func locate(_ template: TargetAppearance, around previous: CGRect, broad: Bool) -> (rect: CGRect, score: Double)? {
        let scales: [Double] = broad ? [0.65,0.85,1,1.25,1.6,2] : [0.85,1,1.18]
        let radiusX = broad ? max(0.10,previous.width*0.75) : previous.width*0.14
        let radiusY = broad ? max(0.10,previous.height*0.75) : previous.height*0.14
        let dx = max(0.012, previous.width * (broad ? 0.22 : 0.14))
        let dy = max(0.012, previous.height * (broad ? 0.22 : 0.14))
        let centersX = [previous.midX] + Array(stride(from: previous.midX-radiusX, through: previous.midX+radiusX+0.00001, by: dx))
        let centersY = [previous.midY] + Array(stride(from: previous.midY-radiusY, through: previous.midY+radiusY+0.00001, by: dy))
        var best: (rect: CGRect, score: Double)?
        for scale in scales {
            let w = previous.width*scale, h = previous.height*scale
            guard w >= 0.02, h >= 0.02, w <= 0.9, h <= 0.9 else { continue }
            for cy in centersY {
                for cx in centersX {
                    let rect = CGRect(x: cx-w/2, y: cy-h/2, width: w, height: h)
                    guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1, rect.maxY <= 1 else { continue }
                    let match = template.match(signature(rect))
                    guard match.color >= 0.60, match.correlation >= (broad ? 0.40 : 0.25), match.score >= (broad ? 0.68 : 0.58) else { continue }
                    if match.score > (best?.score ?? 0) { best = (rect,match.score) }
                }
            }
        }
        return best
    }
}
