import Foundation
import CoreGraphics

struct ForegroundCandidate {
    let rect: CGRect
    let confidence: Double
    let foregroundEvidenceFraction: Double
    let pixels: Int
}

// A stationary painting camera gives us a useful negative reference: hands,
// handles and the desktop should not become the target merely because they resemble it.
final class ForegroundModel {
    private let width: Int, height: Int, background: [UInt8]
    private let weights: [Double]
    private let original: CGRect
    private let expectedPixels: Int
    let ready: Bool

    static func bin(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        let red = Double(r), green = Double(g), blue = Double(b)
        let high = max(red,green,blue), low = min(red,green,blue), delta = high-low
        if high < 24 { return 0 }
        if delta/high < 0.20 { return min(7,1+Int(high/256*7)) }
        var hue: Double
        if high == red { hue = (green-blue)/delta }
        else if high == green { hue = 2+(blue-red)/delta }
        else { hue = 4+(red-green)/delta }
        if hue < 0 { hue += 6 }
        return 8+min(11,Int(hue*2))*2+(delta/high >= 0.45 ? 1 : 0)
    }
    init(frame: AppearanceFrame, target: CGRect) {
        width = frame.width; height = frame.height; background = frame.rgb; original = target
        var positive = [Double](repeating:0.5,count:32), negative = positive, explicitNegative = positive
        let inner = target.insetBy(dx:target.width*0.06,dy:target.height*0.06)
        let excluded = target.insetBy(dx:-target.width*0.15,dy:-target.height*0.15)
        let surrounding = target.insetBy(dx:-target.width*0.45,dy:-target.height*0.35)
        var selected = [Int]()
        var explicitCount = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y*width+x)*3, point = CGPoint(x:(Double(x)+0.5)/Double(width),y:1-(Double(y)+0.5)/Double(height))
            let bin = Self.bin(frame.rgb[i],frame.rgb[i+1],frame.rgb[i+2])
            if inner.contains(point) { positive[bin] += 1; selected.append(bin) }
            else if !excluded.contains(point) { negative[bin] += 1 }
            if surrounding.contains(point) && !excluded.contains(point) {
                explicitNegative[bin] += 1; explicitCount += 1
            }
        } }
        if explicitCount >= 32 {
            let source = explicitNegative
            for bin in 8..<32 {
                let hue = (bin-8)/2
                explicitNegative[8+((hue+11)%12)*2] += source[bin]*0.5
                explicitNegative[8+((hue+11)%12)*2+1] += source[bin]*0.5
                explicitNegative[8+((hue+1)%12)*2] += source[bin]*0.5
                explicitNegative[8+((hue+1)%12)*2+1] += source[bin]*0.5
                explicitNegative[8+hue*2+(1-(bin-8)%2)] += source[bin]*0.5
            }
        }
        let pTotal = positive.reduce(0,+), nTotal = negative.reduce(0,+), eTotal = explicitNegative.reduce(0,+)
        var learned = [Double](repeating:0,count:32)
        for bin in learned.indices {
            let p = positive[bin]/pTotal
            let n = explicitCount < 32 ? negative[bin]/nTotal : 0.5*negative[bin]/nTotal+0.5*explicitNegative[bin]/eTotal
            let ratio = p/max(0.0001,n)
            if p >= 0.015 && ratio >= 2.5 {
                learned[bin] = min(1,log(ratio)/log(12))
            }
        }
        // Prefer distinctive paint hues when available. Common gray shades are
        // unstable under lens blur and can connect the mini to the whole desk.
        let distinctivePaint = selected.filter { $0 >= 8 && learned[$0] >= 0.75 }.count
        let distinctPaintAvailable = distinctivePaint >= 12 && Double(distinctivePaint)/Double(max(1,selected.count)) >= 0.025
        if distinctPaintAvailable {
            for bin in 0..<8 { learned[bin] = 0 }
        }
        weights = learned
        expectedPixels = selected.filter { learned[$0] >= 0.55 }.count
        ready = distinctPaintAvailable && expectedPixels >= 12 && Double(expectedPixels)/Double(max(1,selected.count)) >= 0.025
    }
    var diagnosticSummary: String { "distinct pixels=\(expectedPixels), bins=\(weights.enumerated().filter { $0.element >= 0.55 }.map { "\($0.offset):\(String(format:"%.2f",$0.element))" })" }
    func candidates(in frame: AppearanceFrame, previous: CGRect?, recovering: Bool) -> [ForegroundCandidate] {
        guard ready, frame.width == width, frame.height == height else { return [] }
        let count = width*height
        var strength = [Double](repeating:0,count:count), changed = [Bool](repeating:false,count:count)
        var allowed = previous?.insetBy(dx:-(previous?.width ?? 0)*0.2,dy:-(previous?.height ?? 0)*0.2)
        if let previous = previous {
            let intersection = previous.intersection(original)
            if !intersection.isNull && intersection.width*intersection.height > previous.width*previous.height*0.4 {
                allowed = allowed?.union(original)
            }
        }
        for y in 0..<height { for x in 0..<width {
            let pixel = y*width+x, i = pixel*3
            let weight = weights[Self.bin(frame.rgb[i],frame.rgb[i+1],frame.rgb[i+2])]
            guard weight >= 0.55 else { continue }
            let difference = abs(Int(frame.rgb[i])-Int(background[i])) + abs(Int(frame.rgb[i+1])-Int(background[i+1])) + abs(Int(frame.rgb[i+2])-Int(background[i+2]))
            let point = CGPoint(x:(Double(x)+0.5)/Double(width),y:1-(Double(y)+0.5)/Double(height))
            // The background behind the initially selected mini is unknown.
            // Treating it as a background reference prevents recovery when a
            // covering hand moves away and the mini returns to the same pixels.
            changed[pixel] = difference >= 55 || original.contains(point)
            if changed[pixel] || (!recovering && allowed?.contains(point) == true) { strength[pixel] = weight }
        } }
        // Connect nearby pieces of a painted surface without filling the whole
        // hand or relying on the miniature's upright silhouette.
        var mask = [Bool](repeating:false,count:count)
        for y in 0..<height { for x in 0..<width where strength[y*width+x] > 0 {
            for yy in max(0,y-2)...min(height-1,y+2) { for xx in max(0,x-2)...min(width-1,x+2) { mask[yy*width+xx] = true } }
        } }
        struct Blob { var x0: Int; var y0: Int; var x1: Int; var y1: Int; var pixels: Int; var moved: Int; var weight: Double }
        var blobs = [Blob](), queue = [Int](); queue.reserveCapacity(count)
        for start in 0..<count where mask[start] {
            mask[start] = false; queue.removeAll(keepingCapacity:true); queue.append(start)
            var head = 0, blob = Blob(x0:width,y0:height,x1:0,y1:0,pixels:0,moved:0,weight:0)
            while head < queue.count {
                let pixel = queue[head]; head += 1
                let x = pixel%width, y = pixel/width
                if strength[pixel] > 0 {
                    blob.x0 = min(blob.x0,x); blob.y0 = min(blob.y0,y); blob.x1 = max(blob.x1,x); blob.y1 = max(blob.y1,y)
                    blob.pixels += 1; blob.weight += strength[pixel]; if changed[pixel] { blob.moved += 1 }
                }
                for next in [x>0 ? pixel-1 : -1,x+1<width ? pixel+1 : -1,y>0 ? pixel-width : -1,y+1<height ? pixel+width : -1] where next >= 0 {
                    if mask[next] { mask[next] = false; queue.append(next) }
                }
            }
            if blob.pixels >= 6 { blobs.append(blob) }
        }
        // Separate horns, limbs and cloth often share the learned paint colors.
        var merged = true
        while merged {
            merged = false
            outer: for i in blobs.indices { for j in blobs.indices where j > i {
                let a = blobs[i], b = blobs[j]
                let gapX = max(0,max(a.x0,b.x0)-min(a.x1,b.x1)), gapY = max(0,max(a.y0,b.y0)-min(a.y1,b.y1))
                let reach = max(6,min(22,Int(sqrt(Double(a.pixels+b.pixels))*0.9)))
                if gapX <= reach && gapY <= reach {
                    blobs[i] = Blob(x0:min(a.x0,b.x0),y0:min(a.y0,b.y0),x1:max(a.x1,b.x1),y1:max(a.y1,b.y1),pixels:a.pixels+b.pixels,moved:a.moved+b.moved,weight:a.weight+b.weight)
                    blobs.remove(at:j); merged = true; break outer
                }
            } }
        }
        return blobs.compactMap { blob in
            guard blob.pixels >= max(10,expectedPixels/14) else { return nil }
            let w = Double(blob.x1-blob.x0+1), h = Double(blob.y1-blob.y0+1)
            let padding = max(3,max(w,h)*0.15)
            let rect = CGRect(x:(Double(blob.x0)-padding)/Double(width),y:1-(Double(blob.y1+1)+padding)/Double(height),width:(w+2*padding)/Double(width),height:(h+2*padding)/Double(height)).intersection(CGRect(x:0,y:0,width:1,height:1))
            let ratio = rect.width*rect.height/(original.width*original.height)
            let moved = Double(blob.moved)/Double(blob.pixels)
            guard ratio >= 0.12, ratio <= 7, !recovering || moved >= 0.35 else { return nil }
            let aspect = rect.width*Double(width)/(rect.height*Double(height))
            let originalAspect = original.width*Double(width)/(original.height*Double(height))
            guard max(aspect,1/aspect) <= max(originalAspect,1/originalAspect)*2.0 else { return nil }
            let expectedAtThisScale = max(10,Double(expectedPixels)*ratio)
            let confidence = 0.5*blob.weight/Double(blob.pixels) + 0.25*min(1,Double(blob.pixels)/expectedAtThisScale) + 0.25*min(1,Double(blob.pixels)/(w*h*0.20))
            return ForegroundCandidate(rect:rect,confidence:confidence,foregroundEvidenceFraction:moved,pixels:blob.pixels)
        }.sorted { $0.confidence > $1.confidence }
    }
}

enum ForegroundTrackingResult {
    case found(rect: CGRect, confidence: Double, recovered: Bool)
    case confirming
    case missing
}

final class ForegroundTracker {
    let model: ForegroundModel
    var ready: Bool { model.ready }
    private var previous: CGRect
    private var pending: CGRect?
    private var hits = 0, lastSeenAt = 0.0
    private var lost = false
    init(model: ForegroundModel, seed: CGRect) { self.model = model; previous = seed }
    func update(_ frame: AppearanceFrame, at time: Double) -> ForegroundTrackingResult {
        let candidates = model.candidates(in:frame,previous:previous,recovering:lost).filter { $0.confidence >= 0.70 }
        guard var best = candidates.first else { lost = true; pending = nil; hits = 0; return .missing }
        if !lost, let nearby = candidates.min(by:{
            hypot($0.rect.midX-previous.midX,$0.rect.midY-previous.midY) < hypot($1.rect.midX-previous.midX,$1.rect.midY-previous.midY)
        }), hypot(nearby.rect.midX-previous.midX,nearby.rect.midY-previous.midY) < max(0.08,sqrt(previous.width*previous.height)*0.8) {
            best = nearby
        }
        if lost, candidates.count > 1, best.confidence-candidates[1].confidence < 0.06,
           hypot(best.rect.midX-candidates[1].rect.midX,best.rect.midY-candidates[1].rect.midY) > max(0.18,hypot(best.rect.width,best.rect.height)*1.5) {
            pending = nil; hits = 0; return .confirming
        }
        if let pending = pending, time-lastSeenAt < 0.6,
           hypot(best.rect.midX-pending.midX,best.rect.midY-pending.midY) < max(0.10,hypot(pending.width,pending.height)*0.8) {
            hits += 1
        } else { hits = 1 }
        pending = best.rect; lastSeenAt = time
        guard hits >= 2 else { return .confirming }
        let recovered = lost
        let box: CGRect
        if !lost && hypot(best.rect.midX-previous.midX,best.rect.midY-previous.midY) < hypot(previous.width,previous.height)*0.6 {
            box = CGRect(x:previous.minX*0.25+best.rect.minX*0.75,y:previous.minY*0.25+best.rect.minY*0.75,
                         width:previous.width*0.25+best.rect.width*0.75,height:previous.height*0.25+best.rect.height*0.75)
        } else { box = best.rect }
        previous = box; lost = false
        return .found(rect:box,confidence:best.confidence,recovered:recovered)
    }
}
