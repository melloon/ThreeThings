// Draws the ThreeThings app icon. Usage: swift icon/make_icon.swift <output.png>
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
// Soft glow behind the active dot
let spacing: CGFloat = 138
let active = CGPoint(x: centre.x - spacing, y: centre.y)
let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFF8A4C, 0.38), rgb(0xFF8A4C, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: active, startRadius: 0, endCenter: active, endRadius: 300,
                       options: [])
ctx.restoreGState()

// Faint outer ring, bold inner ring
ctx.setStrokeColor(rgb(0xFFFFFF, 0.16))
ctx.setLineWidth(22)
ctx.addArc(center: centre, radius: 332, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

ctx.setStrokeColor(rgb(0xFFFFFF, 0.96))
ctx.setLineWidth(50)
ctx.addArc(center: centre, radius: 252, startAngle: 0, endAngle: .pi * 2, clockwise: false)
ctx.strokePath()

// Three things: the one in progress is orange, the two still waiting are white
let radius: CGFloat = 54
for index in 0..<3 {
    let x = centre.x + CGFloat(index - 1) * spacing
    let circle = CGRect(x: x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    if index == 0 {
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        let dot = CGGradient(colorsSpace: space, colors: [rgb(0xFFA15C), rgb(0xFF6B3D)] as CFArray,
                             locations: [0, 1])!
        ctx.drawLinearGradient(dot, start: CGPoint(x: x, y: circle.maxY),
                               end: CGPoint(x: x, y: circle.minY), options: [])
        ctx.restoreGState()
    } else {
        ctx.setFillColor(rgb(0xFFFFFF, 0.94))
        ctx.fillEllipse(in: circle)
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
