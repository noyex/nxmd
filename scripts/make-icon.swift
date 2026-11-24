// Draws the app icon as a full-bleed 1024×1024 PNG (macOS applies the rounded mask):
// "md" in clear liquid glass on flat black.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreText

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

// Flat black base
ctx.setFillColor(CGColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0C / 255, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// "md" outline in SF Pro Rounded Heavy
let base = NSFont.systemFont(ofSize: 532, weight: .heavy)
let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 532) ?? base
let line = CTLineCreateWithAttributedString(
    NSAttributedString(string: "md", attributes: [.font: font, .kern: -15]))
let glyphs = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
    let count = CTRunGetGlyphCount(run)
    var ids = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(), &ids)
    CTRunGetPositions(run, CFRange(), &positions)
    for i in 0..<count {
        if let path = CTFontCreatePathForGlyph(runFont, ids[i], nil) {
            glyphs.addPath(path, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
}
// Centre horizontally; baseline sits 66% down the canvas
let width = CTLineGetTypographicBounds(line, nil, nil, nil)
let shape = glyphs.copy(using: [CGAffineTransform(translationX: (size - CGFloat(width)) / 2, y: size * 0.34)])!

func clipped(_ draw: () -> Void) {
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    draw()
    ctx.restoreGState()
}

// Frosted fill
clipped {
    ctx.setFillColor(white(0.30))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
}

// Sheen: brighter towards the top half of the canvas
let sheen = CGGradient(colorsSpace: space, colors: [white(0.36), white(0)] as CFArray, locations: [0, 1])!
clipped {
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size / 2), options: [])
}

// Specular rim: inner half of a stroke, bright top-left and bottom-right
let rim = CGGradient(colorsSpace: space,
                     colors: [white(0.98), white(0.12), white(0.10), white(0.75)] as CFArray,
                     locations: [0, 0.45, 0.7, 1])!
clipped {
    ctx.addPath(shape)
    ctx.setLineWidth(33)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(rim, start: CGPoint(x: size * 0.2, y: size * 0.9),
                           end: CGPoint(x: size * 0.8, y: size * 0.1), options: [])
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
