// Draws the app icon as a full-bleed 1024×1024 PNG (macOS applies the rounded mask).
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// Paper background
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: color(0xFFFFFF), ending: color(0xE9EAEF))!.draw(in: bounds, angle: -90)

// "M"
let font = NSFont.systemFont(ofSize: 470, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color(0x1D1D1F), .kern: -10]
let m = NSAttributedString(string: "M", attributes: attrs)
let mSize = m.size()
let arrowWidth: CGFloat = 190
let gap: CGFloat = 36
let totalWidth = mSize.width + gap + arrowWidth
let originX = (size - totalWidth) / 2
let capHeight = font.capHeight
let baseline = (size - capHeight) / 2
m.draw(at: NSPoint(x: originX, y: baseline + font.descender))

// Down arrow, same height as the cap height
let ax = originX + mSize.width + gap
let shaft: CGFloat = 78
let headHeight: CGFloat = 150
let arrow = NSBezierPath()
let top = baseline + capHeight
let midX = ax + arrowWidth / 2
arrow.move(to: NSPoint(x: midX - shaft / 2, y: top))
arrow.line(to: NSPoint(x: midX + shaft / 2, y: top))
arrow.line(to: NSPoint(x: midX + shaft / 2, y: baseline + headHeight))
arrow.line(to: NSPoint(x: ax + arrowWidth, y: baseline + headHeight))
arrow.line(to: NSPoint(x: midX, y: baseline))
arrow.line(to: NSPoint(x: ax, y: baseline + headHeight))
arrow.line(to: NSPoint(x: midX - shaft / 2, y: baseline + headHeight))
arrow.close()
color(0x0A66D8).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
