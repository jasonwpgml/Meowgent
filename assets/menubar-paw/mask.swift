import AppKit
import Vision
import CoreImage

let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1]), out = args[2]
let ci = CIImage(contentsOf: url)!
let req = VNGenerateForegroundInstanceMaskRequest()
let h = VNImageRequestHandler(ciImage: ci)
try h.perform([req])
guard let r = req.results?.first else { print("no result"); exit(1) }
print("instances:", r.allInstances.count)
for i in r.allInstances {
    let m = try r.generateScaledMaskForImage(forInstances: [i], from: h)
    let mi = CIImage(cvPixelBuffer: m)
    let rep = NSBitmapImageRep(ciImage: mi)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/mask_\(i).png"))
}
