// Draws the OneThing app icon. Usage: swift icon/make_icon.swift <output.png>
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

// macOS icon grid: an 824pt rounded square centred on a 1024pt canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let centre = CGPoint(x: 512, y: 512)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(shape)
ctx.setFillColor(rgb(0x1B1F4B))
ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo, lighter at the top
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [rgb(0x3A3F9E), rgb(0x14163A)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: tile.maxY),
                       end: CGPoint(x: 512, y: tile.minY), options: [])
// Soft glow behind the dot
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFF8A4C, 0.35), rgb(0xFF8A4C, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 330,
                       options: [])
ctx.restoreGState()

// Faint outer ring, bold inner ring
ctx.setLineCap(.round)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
ctx.setLineWidth(26)
ctx.addArc(center: centre, radius: 318, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

ctx.setStrokeColor(rgb(0xFFFFFF, 0.96))
ctx.setLineWidth(58)
ctx.addArc(center: centre, radius: 212, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// The one thing
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: centre.x - 92, y: centre.y - 92, width: 184, height: 184))
ctx.clip()
let dot = CGGradient(colorsSpace: space, colors: [rgb(0xFFA15C), rgb(0xFF6B3D)] as CFArray,
                     locations: [0, 1])!
ctx.drawLinearGradient(dot, start: CGPoint(x: 512, y: 604), end: CGPoint(x: 512, y: 420), options: [])
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
