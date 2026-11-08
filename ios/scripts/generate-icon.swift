import AppKit
import Foundation

// Vector leaf in yearly's existing sage palette; no external image assets.
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes = [40, 58, 60, 80, 87, 120, 180, 1024]
for size in sizes {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(CGColor(red: 0.40, green: 0.48, blue: 0.36, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    context.move(to: CGPoint(x: 302, y: 310))
    context.addCurve(to: CGPoint(x: 750, y: 760), control1: CGPoint(x: 165, y: 640), control2: CGPoint(x: 526, y: 795))
    context.addCurve(to: CGPoint(x: 302, y: 310), control1: CGPoint(x: 799, y: 439), control2: CGPoint(x: 579, y: 209))
    context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.93, alpha: 1))
    context.fillPath()
    context.move(to: CGPoint(x: 263, y: 243))
    context.addCurve(to: CGPoint(x: 643, y: 644), control1: CGPoint(x: 372, y: 433), control2: CGPoint(x: 500, y: 546))
    context.setLineWidth(33)
    context.setLineCap(.round)
    context.setStrokeColor(CGColor(red: 0.40, green: 0.48, blue: 0.36, alpha: 1))
    context.strokePath()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("icon-\(size).png"))
}
