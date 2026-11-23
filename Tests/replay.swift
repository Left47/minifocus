import Foundation
import AVFoundation

@main
enum ReplayCheck {
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else {
            print("Usage: replay-test VIDEO LABELS_JSON [REPORT_JSON]"); exit(2)
        }
        let labels = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        func rect(_ array: [Double]) -> CGRect { CGRect(x:array[0],y:array[1],width:array[2],height:array[3]) }
        let seed = rect(labels["seed"] as! [Double])
        let checks = labels["checks"] as! [[String:Any]]
        let asset = AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { fatalError("No video track") }
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false; reader.add(output); reader.startReading()
        var model: ForegroundModel?, tracker: ForegroundTracker?, nextAt = 0.0
        var results = [[String:Any]](), checked = Set<Int>(), durations = [Double]()
        while let sample = output.copyNextSampleBuffer() {
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time >= nextAt, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            nextAt = time+0.19
            let w = 320, h = CVPixelBufferGetHeight(buffer)*320/CVPixelBufferGetWidth(buffer)
            var rgb = [UInt8](repeating:0,count:w*h*3)
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            let source = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<h { for x in 0..<w {
                let i = y*CVPixelBufferGetHeight(buffer)/h*stride+x*CVPixelBufferGetWidth(buffer)/w*4, p = (y*w+x)*3
                rgb[p] = source[i+2]; rgb[p+1] = source[i+1]; rgb[p+2] = source[i]
            } }
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            let frame = AppearanceFrame(width:w,height:h,rgb:rgb)
            if model == nil {
                model = ForegroundModel(frame:frame,target:seed)
                tracker = ForegroundTracker(model:model!,seed:seed)
                print("Foreground reference ready: \(model!.ready); negatives sampled around the miniature")
                print(model!.diagnosticSummary)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let state = tracker!.update(frame,at:time)
            durations.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            let best: (rect:CGRect,confidence:Double)?
            if case .found(let box,let confidence,_) = state { best = (box,confidence) } else { best = nil }
            for (index,check) in checks.enumerated() where !checked.contains(index) && time >= (check["time"] as! Double) {
                checked.insert(index)
                let expected = (check["rect"] as? [Double]).map(rect)
                var passed = false, overlap = 0.0
                if let expected = expected, let best = best {
                    let intersection = expected.intersection(best.rect)
                    if !intersection.isNull {
                        overlap = intersection.width*intersection.height/(expected.width*expected.height+best.rect.width*best.rect.height-intersection.width*intersection.height)
                        let onTarget = intersection.width*intersection.height/(best.rect.width*best.rect.height)
                        passed = onTarget >= 0.65 && best.rect.width*best.rect.height >= expected.width*expected.height*0.10 && expected.contains(CGPoint(x:best.rect.midX,y:best.rect.midY))
                    }
                } else { passed = expected == nil && best == nil }
                let box = best.map { [$0.rect.minX,$0.rect.minY,$0.rect.width,$0.rect.height] } ?? []
                let result: [String:Any] = ["time":time,"name":check["name"] ?? "","pass":passed,"iou":overlap,"predicted":box,"confidence":best?.confidence ?? 0]
                results.append(result); print(result)
            }
        }
        let report: [String:Any] = ["checks":results,"passed":results.filter { $0["pass"] as! Bool }.count,"total":results.count,
                                  "p95_ms":FramePerformance.percentile(durations,fraction:0.95),"max_ms":durations.max() ?? 0]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        if CommandLine.arguments.count > 3 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[3])) }
        print(String(decoding:data,as:UTF8.self))
        if results.contains(where:{ !($0["pass"] as! Bool) }) { exit(1) }
    }
}
