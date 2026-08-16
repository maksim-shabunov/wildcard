#!/usr/bin/env swift
//
// Draws Resources/AppIcon.iconset and hands it to iconutil.
//
// Run once, by hand, when the mark changes:
//     swift Tools/MakeIcon.swift
//
// Kept as source rather than a checked-in binary blob so the shape, the plum
// and the proportions stay readable and editable. Nothing in the normal build
// depends on it — build.sh only copies the .icns it produces.
//
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Big Sur proportions: the body sits inside the canvas with a generous margin
/// and a continuous corner curve, so it lines up with every other Dock icon.
func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let s = size / 1024                       // everything below is in 1024-space
    let inset = 100 * s
    let body = CGRect(x: inset, y: inset + 12 * s, width: size - inset * 2, height: size - inset * 2)
    let radius = 190 * s

    // Body: muted plum, lit very slightly from above.
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 30 * s,
                  color: NSColor(calibratedWhite: 0, alpha: 0.20).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(srgbRed: 0.541, green: 0.416, blue: 0.510, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(srgbRed: 0.616, green: 0.486, blue: 0.588, alpha: 1).cgColor,
                 NSColor(srgbRed: 0.494, green: 0.376, blue: 0.467, alpha: 1).cgColor] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY),
                           options: [])

    // The mark: a six-spoke asterisk — the wildcard itself. Thick rounded spokes
    // with real space between them, so it still reads at 16pt in the Finder.
    let centre = CGPoint(x: body.midX, y: body.midY)
    let spoke = 250 * s
    let thickness = 92 * s
    let cream = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1).cgColor
    ctx.setStrokeColor(cream)
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.round)
    for i in 0..<3 {
        let angle = CGFloat(i) * .pi / 3 + .pi / 2
        ctx.move(to: CGPoint(x: centre.x - cos(angle) * spoke, y: centre.y - sin(angle) * spoke))
        ctx.addLine(to: CGPoint(x: centre.x + cos(angle) * spoke, y: centre.y + sin(angle) * spoke))
        ctx.strokePath()
    }
    // A small plum dot at the crossing keeps the centre from going heavy.
    ctx.setFillColor(NSColor(srgbRed: 0.478, green: 0.365, blue: 0.451, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: centre.x - 30 * s, y: centre.y - 30 * s, width: 60 * s, height: 60 * s))

    // A single soft highlight along the top edge instead of a border.
    ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.16).cgColor)
    ctx.setLineWidth(3 * s)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5 * s, dy: 1.5 * s),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let rep = draw(size: CGFloat(base * scale))
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent(name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path,
               "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
