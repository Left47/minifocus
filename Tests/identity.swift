import Foundation
import AVFoundation

@main
enum IdentitySmokeTest {
    static func main() {
        var optional: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &optional)
        guard status == kCVReturnSuccess, let buffer = optional else { fatalError("Cannot create fixture") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<480 {
            for x in 0..<640 {
                let i = y*stride+x*4
                bytes[i] = UInt8(25+(x/30)%5*20); bytes[i+1] = UInt8(35+(y/25)%5*20); bytes[i+2] = 100; bytes[i+3] = 255
                if x >= 224 && x < 416 && y >= 144 && y < 336 {
                    let check = ((x-224)/24+(y-144)/24)%3
                    bytes[i] = check == 0 ? 25 : 210
                    bytes[i+1] = check == 1 ? 50 : 220
                    bytes[i+2] = check == 2 ? 30 : 220
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let identity = VisionIdentity()
        let target = CGRect(x: 0.35,y: 0.3,width: 0.3,height: 0.4)
        guard identity.enroll(buffer, rect: target) else { fatalError("Feature-print enrollment failed") }
        guard identity.accepts(buffer, rect: target) else { fatalError("Original target was rejected") }
        guard !identity.accepts(buffer, rect: CGRect(x:0,y:0,width:0.3,height:0.4)) else { fatalError("Known background was accepted") }
        print("PASS: native Vision feature-print enrollment, exact target match, and background rejection")
    }
}
