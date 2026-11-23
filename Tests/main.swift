import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fatalError("FAIL: \(message)") }
}
func simulate(current: Int, wide: Bool, peak: Int?, noisy: Bool = false) -> Int {
    let sweep = FocusSweep(current: current, minimum: 0, maximum: 255, step: 5, wide: wide)
    var time = 0.0, position = current, frames = 0
    sweep.didMove(at: time)
    while frames < 1500 {
        frames += 1; time += 0.11
        var score = peak.map { 1000 / (1 + pow(Double(position-$0) / 12, 2)) } ?? 100
        if noisy && frames % 3 == 0 { score *= 20 }
        switch sweep.add(score: score, at: time) {
        case .waiting: break
        case .move(let next):
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
print("PASS: \(checks) checks — search, noise rejection, settling, tracking gates, geometry, and sharpness")
