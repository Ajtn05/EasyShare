#!/usr/bin/env swift
// Regenerates App and ShareExtension icon assets.
// Run with: cd macos && swift Tools/make-icons.swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// Mark geometry in a normalized 100×100 coordinate space.
private enum Glyph {
    static let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    static func tray(radius: CGFloat = 13) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 18, y: 50))
        path.addArc(tangent1End: CGPoint(x: 18, y: 18), tangent2End: CGPoint(x: 82, y: 18), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 82, y: 18), tangent2End: CGPoint(x: 82, y: 50), radius: radius)
        path.addLine(to: CGPoint(x: 82, y: 50))
        return path
    }

    static func arrowOnlyScale() -> CGFloat { 1.25 }

    static func arrow() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 50, y: 33))
        path.addLine(to: CGPoint(x: 50, y: 82))
        path.move(to: CGPoint(x: 36, y: 68))
        path.addLine(to: CGPoint(x: 50, y: 82))
        path.addLine(to: CGPoint(x: 64, y: 68))
        return path
    }
}

private func squircle(in rect: CGRect, exponent: CGFloat = 5, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let power = 2 / exponent

    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), power)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), power)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

private func makeContext(_ pixels: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    return context
}

private func strokeGlyph(
    in context: CGContext, rect: CGRect, weight: CGFloat, color glyphColor: CGColor,
    includeTray: Bool = true
) {
    let scale = rect.width / Glyph.box.width
    var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        .scaledBy(x: scale, y: scale)

    context.saveGState()
    context.setStrokeColor(glyphColor)
    context.setLineWidth(weight * scale)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    for path in (includeTray ? [Glyph.tray(), Glyph.arrow()] : [Glyph.arrow()]) {
        context.addPath(path.copy(using: &transform)!)
        context.strokePath()
    }
    context.restoreGState()
}

/// Draws a full-color application icon.
private func renderAppIcon(pixels: Int, detailed: Bool) -> CGImage {
    let tiny = pixels <= 16
    let context = makeContext(pixels)
    let s = CGFloat(pixels) / 1024

    let plate = CGRect(x: 100 * s, y: 116 * s, width: 824 * s, height: 824 * s)
    let shape = squircle(in: plate)

    if detailed {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: color(0, 0, 0, 0.30)
        )
        context.addPath(shape)
        context.setFillColor(color(0, 0, 0, 1))
        context.fillPath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(shape)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: srgb,
        colors: [color(0.35, 0.65, 1.00), color(0.15, 0.33, 0.86)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )

    if detailed {
        let gloss = CGGradient(
            colorsSpace: srgb,
            colors: [color(1, 1, 1, 0.16), color(1, 1, 1, 0)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gloss,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.maxY - plate.height * 0.45),
            options: []
        )
    }
    context.restoreGState()

    let fraction: CGFloat = detailed ? 0.62 : 0.72
    let weight: CGFloat = detailed ? 10.5 : 12.5
    let side = plate.width * fraction * (tiny ? Glyph.arrowOnlyScale() : 1)
    let glyphRect = CGRect(
        x: plate.midX - side / 2,
        y: plate.midY - side / 2 - (tiny ? side * 0.07 : 0),
        width: side, height: side
    )
    strokeGlyph(
        in: context, rect: glyphRect, weight: weight, color: color(1, 1, 1), includeTray: !tiny
    )

    return context.makeImage()!
}

/// Draws a menu-bar template image.
private func renderMenuBarIcon(pixels: Int) -> CGImage {
    let context = makeContext(pixels)
    let side = CGFloat(pixels) * 0.94
    let rect = CGRect(
        x: (CGFloat(pixels) - side) / 2, y: (CGFloat(pixels) - side) / 2,
        width: side, height: side
    )
    strokeGlyph(in: context, rect: rect, weight: 9.5, color: color(0, 0, 0))
    return context.makeImage()!
}

// MARK: - Output

private let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tools/
    .deletingLastPathComponent()   // macos/

private func write(_ image: CGImage, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not write \(url.path)")
    }
    print("  \(url.path.replacingOccurrences(of: root.path + "/", with: ""))")
}

private func writeJSON(_ body: String, to url: URL) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try! body.write(to: url, atomically: true, encoding: .utf8)
}

private let assets = root.appendingPathComponent("App/Assets.xcassets")
private let extensionAssets = root.appendingPathComponent("ShareExtension/Assets.xcassets")

private let catalogRoot = #"""
{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""#

writeJSON(catalogRoot, to: assets.appendingPathComponent("Contents.json"))
writeJSON(catalogRoot, to: extensionAssets.appendingPathComponent("Contents.json"))


print("AppIcon:")

private let iconSlots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

private var iconEntries: [String] = []
for slot in iconSlots {
    let pixels = slot.points * slot.scale
    let suffix = slot.scale == 1 ? "" : "@\(slot.scale)x"
    let name = "icon_\(slot.points)x\(slot.points)\(suffix).png"
    write(
        renderAppIcon(pixels: pixels, detailed: pixels > 64),
        to: assets.appendingPathComponent("AppIcon.appiconset/\(name)")
    )
    iconEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.points)x\(slot.points)"
        }
    """)
}

writeJSON(
    """
    {
      "images" : [
    \(iconEntries.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """,
    to: assets.appendingPathComponent("AppIcon.appiconset/Contents.json")
)


private func writeMenuBarImageSet(named name: String) {
    print("\(name):")
    var entries: [String] = []
    for scale in 1...2 {
        let file = "\(name)\(scale == 1 ? "" : "@\(scale)x").png"
        write(
            renderMenuBarIcon(pixels: 18 * scale),
            to: assets.appendingPathComponent("\(name).imageset/\(file)")
        )
        entries.append("""
            { "filename" : "\(file)", "idiom" : "mac", "scale" : "\(scale)x" }
        """)
    }
    writeJSON(
        """
        {
          "images" : [
        \(entries.joined(separator: ",\n"))
          ],
          "info" : { "author" : "xcode", "version" : 1 },
          "properties" : { "template-rendering-intent" : "template" }
        }
        """,
        to: assets.appendingPathComponent("\(name).imageset/Contents.json")
    )
}

writeMenuBarImageSet(named: "MenuBarIcon")

print("ShareIcon:")
var shareEntries: [String] = []
for scale in 1...2 {
    let file = "ShareIcon\(scale == 1 ? "" : "@\(scale)x").png"
    write(
        renderAppIcon(pixels: 48 * scale, detailed: true),
        to: extensionAssets.appendingPathComponent("ShareIcon.imageset/\(file)")
    )
    shareEntries.append("""
        { "filename" : "\(file)", "idiom" : "mac", "scale" : "\(scale)x" }
    """)
}
writeJSON(
    """
    {
      "images" : [
    \(shareEntries.joined(separator: ",\n"))
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """,
    to: extensionAssets.appendingPathComponent("ShareIcon.imageset/Contents.json")
)

print("done")
