import Foundation
import AVFoundation
import CoreImage

@main
enum IdentitySmokeTest {
    static func main() {
        setbuf(stdout,nil)
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
                if x >= 224 && x < 352 && y >= 144 && y < 336 {
                    let check = ((x-224)/24+(y-144)/24)%3
                    bytes[i] = check == 0 ? 25 : 210
                    bytes[i+1] = check == 1 ? 50 : 220
                    bytes[i+2] = check == 2 ? 30 : 220
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let identity = VisionIdentity()
        let target = CGRect(x: 0.35,y: 0.3,width: 0.2,height: 0.4)
        guard identity.enroll(buffer, rect: target) else { fatalError("Feature-print enrollment failed") }
        guard identity.accepts(buffer, rect: target) else { fatalError("Original target was rejected") }
        guard !identity.accepts(buffer, rect: CGRect(x:0,y:0,width:0.3,height:0.4)) else { fatalError("Known background was accepted") }
        let image = CIImage(cvPixelBuffer:buffer)
        let crop = CGRect(x:224,y:144,width:128,height:192)
        let patch = image.cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.midX,y:-crop.midY))
        let context = CIContext(options:[.useSoftwareRenderer:true])
        let background = CIImage(color:CIColor(red:0.15,green:0.15,blue:0.2)).cropped(to:image.extent)
        for angle in [7,17,45,90,137,180,225,270,345] {
            let turned = patch.transformed(by:CGAffineTransform(rotationAngle:Double(angle)*Double.pi/180))
                .transformed(by:CGAffineTransform(translationX:crop.midX,y:crop.midY))
            var output: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault,640,480,kCVPixelFormatType_32BGRA,nil,&output)
            guard let output = output else { fatalError("Cannot allocate rotated fixture") }
            context.render(turned.composited(over:background),to:output)
            let extent = turned.extent
            let box = CGRect(x:extent.minX/640,y:extent.minY/480,width:extent.width/640,height:extent.height/480)
            guard identity.accepts(output,rect:box) else { fatalError("Rotated target rejected at \(angle) degrees") }
            guard !identity.accepts(output,rect:CGRect(x:0,y:0,width:0.2,height:0.4)) else { fatalError("Background accepted after rotation \(angle)") }
            print("PASS: target rotation \(angle) degrees; background still rejected")
        }
        print("PASS: native Vision identity, rotation, and background-rejection tests")
    }
}
