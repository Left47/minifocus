import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}
check(IdentityDecision.accepts(positive: 0.1, negative: 0.9, separation: 0.8), "Strong miniature identity is accepted")
check(!IdentityDecision.accepts(positive: 0.4, negative: 0.3, separation: 0.8), "Background-like candidate is rejected despite appearance match")
check(!IdentityDecision.accepts(positive: 0.7, negative: 0.9, separation: 0.8), "Candidate too far from the learned miniature is rejected")
check(!IdentityDecision.accepts(positive: 0.3, negative: 0.35, separation: 0.8), "Ambiguous identity stays in looking mode")
check(!IdentityDecision.accepts(positive: 0, negative: 0, separation: 0), "Missing identity calibration cannot enable autofocus recovery")
func simulate(current: Int, wide: Bool, peak: Int?, noisy: Bool = false, exhaustive: Bool = false, onProbe: ((Int) -> Void)? = nil) -> Int {
    let sweep = FocusSweep(current: current, minimum: 0, maximum: 255, step: 5, wide: wide, exhaustive: exhaustive)
    var time = 0.0, position = current, frames = 0
    sweep.didMove(at: time)
    while frames < 1500 {
        frames += 1; time += 0.11
        var score = peak.map { 1000 / (1 + pow(Double(position-$0) / 12, 2)) } ?? 100
        if noisy && frames % 3 == 0 { score *= 20 }
        switch sweep.add(score: score, at: time) {
        case .waiting: break
        case .move(let next):
            onProbe?(next)
            check(next >= 0 && next <= 255 && next % 5 == 0, "Every focus command is in range and aligned")
            position = next; sweep.didMove(at: time)
        case .finished(let best, _): return best
        }
    }
    fatalError("Sweep did not finish")
}
check(simulate(current: 45, wide: true, peak: 110) == 110, "Wide scan refines around the coarse peak")
check(simulate(current: 45, wide: false, peak: 55) == 55, "Local scan follows nearby focus changes")
check(simulate(current: 45, wide: true, peak: nil) == 45, "Flat scene does not cause focus drift")
check(simulate(current: 45, wide: true, peak: 110, noisy: true) == 110, "Median scoring rejects single-frame spikes")
check(simulate(current: 0, wide: false, peak: 0) == 0, "Lower-bound search stays in range")
check(simulate(current: 255, wide: false, peak: 255) == 255, "Upper-bound search stays in range")
var quickProbes = 0, fullProbes = 0
check(simulate(current: 45, wide: true, peak: 55, onProbe: { _ in quickProbes += 1 }) == 55, "Quick acquisition finds nearby peak")
check(simulate(current: 45, wide: true, peak: 55, exhaustive: true, onProbe: { _ in fullProbes += 1 }) == 55, "Full fallback finds nearby peak")
check(quickProbes < fullProbes, "Quick acquisition uses fewer lens movements for a nearby subject")
check(simulate(current: 45, wide: true, peak: 230) == 230, "Expanding search still reaches distant lens positions")
let settling = FocusSweep(current: 45, minimum: 0, maximum: 255, step: 5, wide: false)
settling.didMove(at: 5)
if case .waiting = settling.add(score: 100, at: 5.1) {} else { fatalError("Must ignore frames while lens settles") }
let rect = CGRect(x: 0.4, y: 0.3, width: 0.15, height: 0.25)
check(TargetGeometry.acceptable(rect.offsetBy(dx: 0.02, dy: 0), after: rect, confidence: 0.9), "Small target movement is accepted")
check(!TargetGeometry.acceptable(rect.offsetBy(dx: 0.4, dy: 0), after: rect, confidence: 0.9), "Abrupt tracker jumps are rejected")
check(!TargetGeometry.acceptable(rect, after: rect, confidence: 0.4), "Low-confidence target is rejected")
check(!TargetGeometry.acceptable(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), after: rect, confidence: 0.9), "Sudden background-sized target is rejected")
let fitted = TargetGeometry.imageRect(in: CGRect(x: 0, y: 0, width: 1000, height: 1000), width: 1920, height: 1080)
check(abs(fitted.minX) < 0.001 && abs(fitted.minY-218.75) < 0.001 && abs(fitted.width-1000) < 0.001 && abs(fitted.height-562.5) < 0.001, "Selection geometry accounts for letterboxing")
let roi = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
var acquisition = AcquisitionGate()
acquisition.begin()
check(!acquisition.releaseIfSettled(at: 1000), "Acquisition never enables tracking before the sweep finishes")
acquisition.finishSweep(at: 1000)
check(!acquisition.releaseIfSettled(at: 1000.3), "Tracker waits while final lens position settles")
check(acquisition.releaseIfSettled(at: 1000.5) && !acquisition.isAcquiring, "Tracking resumes after acquisition and final settling")
check(!acquisition.releaseIfSettled(at: 1001), "Acquisition transition happens only once")
acquisition.begin(); acquisition.cancel()
check(!acquisition.isAcquiring && !acquisition.releaseIfSettled(at: 2000), "Stopping cancels pending acquisition")
let sharp = FocusMetric.score(width: 128, height: 128, roi: roi) { x, y in (x / 4 + y / 4) % 2 == 0 ? 220 : 30 }
let blurred = FocusMetric.score(width: 128, height: 128, roi: roi) { x, y in 125 + sin(Double(x)/8) * 10 + cos(Double(y)/8) * 10 }
check(sharp > blurred * 10, "Sharp texture scores higher than blurred texture")
check(FocusMetric.score(width: 128, height: 128, roi: roi) { _,_ in 100 } == 0, "Flat target scores zero")
func testFrame(target: CGRect, addDistractor: Bool = false) -> AppearanceFrame {
    let width = 320, height = 180
    var rgb = [UInt8](repeating: 55, count: width*height*3)
    for y in 0..<height {
        for x in 0..<width {
            let px = (Double(x)+0.5)/Double(width), py = 1-(Double(y)+0.5)/Double(height)
            let i = (y*width+x)*3
            if target.contains(CGPoint(x: px, y: py)) {
                let u = (px-target.minX)/target.width, v = (py-target.minY)/target.height
                let colors: [[UInt8]] = [[15,130,55],[220,225,215],[25,35,30],[70,190,100]]
                let index = (Int(u*4)+Int(v*5)*3) % 4
                rgb[i] = colors[index][0]; rgb[i+1] = colors[index][1]; rgb[i+2] = colors[index][2]
            } else if addDistractor && px > 0.55 && px < 0.9 && py > 0.15 && py < 0.8 {
                rgb[i] = 205; rgb[i+1] = 145; rgb[i+2] = 110
            }
        }
    }
    return AppearanceFrame(width: width, height: height, rgb: rgb)
}
let referenceBox = CGRect(x: 0.3, y: 0.3, width: 0.15, height: 0.25)
let referenceFrame = testFrame(target: referenceBox)
let signature = referenceFrame.signature(referenceBox)
check(signature.match(signature).score > 0.999, "Appearance matches itself")
for turns in [1,2,3] {
    var pixels = referenceFrame.rgb, w = referenceFrame.width, h = referenceFrame.height
    for _ in 0..<turns {
        var output = [UInt8](repeating: 0,count: pixels.count)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            output[(x*h+(h-1-y))*3+c] = pixels[(y*w+x)*3+c]
        } } }
        pixels = output; let oldW = w; w = h; h = oldW
    }
    var box = referenceBox
    for _ in 0..<turns { box = CGRect(x:box.minY,y:1-box.maxX,width:box.height,height:box.width) }
    let actual = AppearanceFrame(width:w,height:h,rgb:pixels).signature(box)
    check(signature.rotationMatch(actual).correlation > 0.90, "Pixel-rotated fixture matches at \(turns*90) degrees")
}
let enlargedBox = CGRect(x: referenceBox.midX-0.15*1.6/2+0.03, y: referenceBox.midY-0.25*1.6/2, width: 0.15*1.6, height: 0.25*1.6)
let closeFrame = testFrame(target: enlargedBox, addDistractor: true)
let foreground = ForegroundModel(frame:referenceFrame,target:referenceBox)
check(foreground.ready, "Foreground learns a distinct paint signature from the selected target")
let steadyForeground = foreground.candidates(in:referenceFrame,previous:referenceBox,recovering:false)
check(steadyForeground.first?.rect.contains(CGPoint(x:referenceBox.midX,y:referenceBox.midY)) == true, "Stationary mini remains a foreground candidate at the tracked location")
let closeForeground = foreground.candidates(in:closeFrame,previous:referenceBox,recovering:true)
check(closeForeground.first?.rect.contains(CGPoint(x:enlargedBox.midX,y:enlargedBox.midY)) == true, "Foreground finds the closer miniature without requiring the old silhouette")
let recovered = closeFrame.locate(signature, around: referenceBox, broad: true)
check(recovered != nil, "Multiscale recovery finds a closer miniature")
if let recovered = recovered {
    check(recovered.rect.width > referenceBox.width*1.3, "Recovery expands the tracking box for a close-up")
    check(abs(recovered.rect.midX-enlargedBox.midX) < 0.05 && abs(recovered.rect.midY-enlargedBox.midY) < 0.05, "Recovery stays on the miniature despite nearby distractor")
}
let noTarget = testFrame(target: CGRect(x: 2,y: 2,width: 0.1,height: 0.1), addDistractor: true)
check(foreground.candidates(in:noTarget,previous:referenceBox,recovering:true).isEmpty, "Foreground rejects the face-colored distractor when the miniature is absent")
check(noTarget.locate(signature, around: referenceBox, broad: true) == nil, "Recovery rejects an unrelated background and skin-colored distractor")
let returnedBox = CGRect(x: 0.73, y: 0.65, width: 0.15, height: 0.25)
let returnedFrame = testFrame(target: returnedBox, addDistractor: true)
check(foreground.candidates(in:returnedFrame,previous:referenceBox,recovering:true).first?.rect.contains(CGPoint(x:returnedBox.midX,y:returnedBox.midY)) == true, "Foreground returns to a miniature at a new frame location")
let foregroundTracker = ForegroundTracker(model:foreground,seed:referenceBox)
if case .confirming = foregroundTracker.update(referenceFrame,at:0) { checks += 1 } else { fatalError("New foreground target must be confirmed across frames") }
if case .found = foregroundTracker.update(referenceFrame,at:0.15) { checks += 1 } else { fatalError("Confirmed miniature should be tracked") }
if case .missing = foregroundTracker.update(noTarget,at:0.30) { checks += 1 } else { fatalError("Empty frame should hold focus and preserve the reference") }
if case .confirming = foregroundTracker.update(returnedFrame,at:100) { checks += 1 } else { fatalError("Returning object cannot immediately restart autofocus") }
if case .found(let box,_,let recovered) = foregroundTracker.update(returnedFrame,at:100.15) {
    check(recovered && box.contains(CGPoint(x:returnedBox.midX,y:returnedBox.midY)), "Mini is recovered after a long absence at a different location")
} else { fatalError("Confirmed returned miniature should recover") }
var twoTargets = returnedFrame.rgb
for y in 0..<180 { for x in 0..<320 {
    let i = (y*320+x)*3
    if referenceBox.contains(CGPoint(x:(Double(x)+0.5)/320,y:1-(Double(y)+0.5)/180)) {
        twoTargets[i] = referenceFrame.rgb[i]; twoTargets[i+1] = referenceFrame.rgb[i+1]; twoTargets[i+2] = referenceFrame.rgb[i+2]
    }
} }
_ = foregroundTracker.update(noTarget,at:101)
let ambiguousFrame = AppearanceFrame(width:320,height:180,rgb:twoTargets)
if case .confirming = foregroundTracker.update(ambiguousFrame,at:101.2) { checks += 1 } else { fatalError("Two equally likely separated objects must not trigger focus movement") }
let continuing = ForegroundTracker(model:foreground,seed:referenceBox)
_ = continuing.update(referenceFrame,at:0); _ = continuing.update(referenceFrame,at:0.15)
if case .found(let box,_,_) = continuing.update(ambiguousFrame,at:0.3) {
    check(referenceBox.contains(CGPoint(x:box.midX,y:box.midY)), "A second similar foreground object does not steal an already tracked mini")
} else { fatalError("Existing miniature should remain tracked when another object enters") }
// A same-colored shelf object is a negative example when it was stationary
// during enrollment; its paint similarity must not make it the recovered mini.
let shelfBox = CGRect(x:0.72,y:0.65,width:0.12,height:0.20)
let shelfFrame = testFrame(target:shelfBox)
var initialWithShelf = referenceFrame.rgb
for y in 0..<180 { for x in 0..<320 {
    if shelfBox.contains(CGPoint(x:(Double(x)+0.5)/320,y:1-(Double(y)+0.5)/180)) {
        let i = (y*320+x)*3
        initialWithShelf[i] = shelfFrame.rgb[i]; initialWithShelf[i+1] = shelfFrame.rgb[i+1]; initialWithShelf[i+2] = shelfFrame.rgb[i+2]
    }
} }
let shelfModel = ForegroundModel(frame:AppearanceFrame(width:320,height:180,rgb:initialWithShelf),target:referenceBox)
check(shelfModel.ready, "Distinct miniature paint can be learned even when the room contains a similar color")
check(shelfModel.candidates(in:shelfFrame,previous:referenceBox,recovering:true).isEmpty, "Unchanged same-colored shelf object cannot replace the absent mini")
func handheldFrame(visible: Bool, shiftedHand: Bool = false, cover: CGRect? = nil) -> AppearanceFrame {
    var rgb = [UInt8](repeating:55,count:320*180*3)
    let palm = shiftedHand ? CGRect(x:0.50,y:0.20,width:0.25,height:0.50) : referenceBox.insetBy(dx:-0.06,dy:-0.10)
    for y in 0..<180 { for x in 0..<320 {
        let p = CGPoint(x:(Double(x)+0.5)/320,y:1-(Double(y)+0.5)/180), i = (y*320+x)*3
        if palm.contains(p) { rgb[i]=215; rgb[i+1]=145; rgb[i+2]=115 }
        let u = (p.x-referenceBox.midX)/(referenceBox.width*0.44), v = (p.y-referenceBox.midY)/(referenceBox.height*0.44)
        if visible && u*u+v*v <= 1 {
            rgb[i]=referenceFrame.rgb[i]; rgb[i+1]=referenceFrame.rgb[i+1]; rgb[i+2]=referenceFrame.rgb[i+2]
        }
        if cover?.contains(p) == true { rgb[i]=215; rgb[i+1]=145; rgb[i+2]=115 }
    } }
    return AppearanceFrame(width:320,height:180,rgb:rgb)
}
let heldMini = handheldFrame(visible:true)
let handModel = ForegroundModel(frame:heldMini,target:referenceBox)
check(handModel.ready, "Mini paint can be learned with a hand in the selection and no visible face")
check(handModel.candidates(in:handheldFrame(visible:false,shiftedHand:true),previous:referenceBox,recovering:true).isEmpty, "A moving hand alone cannot become the recovered target")
let fingerCover = CGRect(x:referenceBox.midX,y:referenceBox.minY,width:referenceBox.width,height:referenceBox.height)
let partiallyCovered = handheldFrame(visible:true,cover:fingerCover)
check(handModel.candidates(in:partiallyCovered,previous:referenceBox,recovering:false).first?.rect.midX ?? 1 < referenceBox.midX+0.03, "Partial finger occlusion keeps focus on exposed painted surface")
let handTracker = ForegroundTracker(model:handModel,seed:referenceBox)
_ = handTracker.update(heldMini,at:0); _ = handTracker.update(heldMini,at:0.15)
if case .missing = handTracker.update(handheldFrame(visible:false),at:0.3) { checks += 1 } else { fatalError("A fully covered mini must hold focus") }
_ = handTracker.update(heldMini,at:0.45)
if case .found(_,_,let recovered) = handTracker.update(heldMini,at:0.60) { check(recovered,"Mini is recovered after the covering hand moves away") }
else { fatalError("Uncovered miniature must be recoverable without a face reference") }
var brushPixels = noTarget.rgb
let greenBrush = CGRect(x:0.50,y:0.10,width:0.018,height:0.65)
let holder = CGRect(x:referenceBox.minX,y:0.05,width:referenceBox.width,height:0.20)
for y in 0..<180 { for x in 0..<320 {
    let point = CGPoint(x:(Double(x)+0.5)/320,y:1-(Double(y)+0.5)/180), i = (y*320+x)*3
    if greenBrush.contains(point) { brushPixels[i]=15; brushPixels[i+1]=130; brushPixels[i+2]=55 }
    if holder.contains(point) { brushPixels[i]=20; brushPixels[i+1]=20; brushPixels[i+2]=20 }
} }
check(handModel.candidates(in:AppearanceFrame(width:320,height:180,rgb:brushPixels),previous:referenceBox,recovering:true).isEmpty, "A thin same-paint-colored brush and dark painting handle do not replace the missing mini")
let crossingBrush = CGRect(x:referenceBox.midX-0.01,y:referenceBox.minY-0.05,width:0.02,height:referenceBox.height+0.10)
let brushedMini = handheldFrame(visible:true,cover:crossingBrush)
check(!handModel.candidates(in:brushedMini,previous:referenceBox,recovering:false).isEmpty, "Visible painted surfaces remain available when a brush crosses the mini")
var neutralPixels = referenceFrame.rgb
for i in stride(from:0,to:neutralPixels.count,by:3) {
    let gray = UInt8((Int(neutralPixels[i])+Int(neutralPixels[i+1])+Int(neutralPixels[i+2]))/3)
    neutralPixels[i]=gray;neutralPixels[i+1]=gray;neutralPixels[i+2]=gray
}
check(!ForegroundModel(frame:AppearanceFrame(width:320,height:180,rgb:neutralPixels),target:referenceBox).ready, "A neutral-only target uses the image-identity fallback rather than a broad gray-color lock")
let searchStarted = Date()
let returned = returnedFrame.reidentify([signature], reference: referenceBox, originalSize: referenceBox.size)
let globalSearchSeconds = Date().timeIntervalSince(searchStarted)
check(returned != nil, "Whole-frame search rediscovers a miniature returned far from its last position")
if let returned = returned {
    check(abs(returned.rect.midX-returnedBox.midX) < 0.045 && abs(returned.rect.midY-returnedBox.midY) < 0.045, "Global rediscovery chooses the returned miniature")
}
check(noTarget.reidentify([signature], reference: referenceBox, originalSize: referenceBox.size) == nil, "Off-screen miniature is not replaced by an unrelated subject")
var confirmation = ReacquisitionConfirmation()
check(!confirmation.observe(returnedBox, at: 0), "One candidate cannot immediately restart autofocus")
check(confirmation.observe(returnedBox.offsetBy(dx: 0.01,dy: 0), at: 0.5), "Consistent returned target is confirmed across frames")
confirmation.reset()
check(!confirmation.observe(returnedBox, at: 100), "Off-screen wait has no stale confirmation")
check(!confirmation.observe(referenceBox, at: 100.5), "A jump to a different candidate does not count as confirmation")
check(confirmation.observe(referenceBox, at: 101), "A stable new location is eventually confirmed")
var performance = FramePerformance(started:0)
for frame in 0...30 { performance.receive(presentationTime:Double(frame)/30) }
performance.drop(); performance.drop()
for duration in 1...100 { performance.finish(mode:"following",milliseconds:Double(duration)) }
let performanceReport = performance.report(at:5)
let modes = performanceReport["modes"] as! [String:[String:Any]]
check(abs((performanceReport["camera_fps"] as! Double)-30) < 0.001, "Performance reports delivered camera FPS from presentation timestamps")
check(performanceReport["capture_drops"] as! Int == 2, "Performance keeps capture drops separate from analysis throttling")
check(modes["following"]!["p95_ms"] as! Double == 95, "Performance p95 includes slow frames")
check(modes["following"]!["max_ms"] as! Double == 100, "Performance preserves worst-case processing time")
check(FramePerformance.percentile([],fraction:0.95) == 0, "Empty performance samples are handled")
print("PASS: \(checks) checks — focus, rotation, recovery, identity gates, and performance measurements")
print("Nearby acquisition lens probes: quick=\(quickProbes), full=\(fullProbes)")
print(String(format: "Whole-frame recovery search: %.3f seconds", globalSearchSeconds))
