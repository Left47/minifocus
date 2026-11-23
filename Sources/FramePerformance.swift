import Foundation

struct FramePerformance {
    private let started: Double
    private var firstPTS: Double?, lastPTS: Double?
    private(set) var received = 0, processed = 0, dropped = 0
    private var timings: [String:[Double]] = [:]
    init(started: Double) { self.started = started }
    mutating func receive(presentationTime: Double) {
        received += 1
        if presentationTime.isFinite {
            if firstPTS == nil { firstPTS = presentationTime }
            lastPTS = presentationTime
        }
    }
    mutating func drop() { dropped += 1 }
    mutating func finish(mode: String, milliseconds: Double) {
        processed += 1
        timings[mode,default:[]].append(milliseconds)
        if timings[mode]!.count > 600 { timings[mode]!.removeFirst() }
    }
    static func percentile(_ values: [Double], fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count-1,max(0,Int(ceil(fraction*Double(sorted.count)))-1))]
    }
    private var cameraFPS: Double {
        guard let firstPTS = firstPTS, let lastPTS = lastPTS, lastPTS > firstPTS else { return 0 }
        return Double(received-1)/(lastPTS-firstPTS)
    }
    func report(at time: Double) -> [String:Any] {
        var modes: [String:Any] = [:]
        for (mode,values) in timings {
            modes[mode] = ["samples":values.count,"p50_ms":Self.percentile(values,fraction:0.5),
                           "p95_ms":Self.percentile(values,fraction:0.95),"max_ms":values.max() ?? 0]
        }
        return ["wall_time_unix":Date().timeIntervalSince1970,"elapsed_seconds":max(0,time-started),"camera_fps":cameraFPS,"camera_frames":received,
                "processed_frames":processed,"capture_drops":dropped,"modes":modes]
    }
    var summary: String {
        let all = timings.values.flatMap { $0 }
        return String(format:"Camera delivery %.1f fps  ·  Analysis p95 %.1f ms  ·  Reported drops %d",cameraFPS,Self.percentile(all,fraction:0.95),dropped)
    }
}
