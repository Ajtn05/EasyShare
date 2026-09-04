#!/usr/bin/env swift
//
// Regenerates every image in App/Assets.xcassets and
// ShareExtension/Assets.xcassets.
//
//     cd macos && swift Tools/make-icons.swift
//
// Why a generator rather than checked-in PNGs: the same mark has to exist at
// ten pixel sizes in two colour treatments, and hand-exported bitmaps drift the
// moment one of them is touched. This file is the source of truth for the
// artwork; the PNGs are build output that happens to be committed so a checkout
// builds without running this.
//
// It deliberately uses only CoreGraphics + ImageIO — no AppKit, no Xcode, no
// design tool — so it runs anywhere `swift` does.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// The mark, drawn in a 100x100 space with y pointing up.
///
/// A tray with an arrow leaving through its opening: the same metaphor the
/// Share menu itself uses, which is where this app is invoked from. It is three
/// stroked paths and nothing else, because the 16pt slot has to stay readable —
/// anything with a fill and a counter turns to porridge at that size.
private enum Glyph {
    static let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    /// The open bracket the arrow leaves from. Wide and shallow: raise the
    /// sides or narrow the span and the mark stops reading as a tray and starts
    /// reading as a house with a roof.
    static func tray(radius: CGFloat = 13) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 18, y: 50))
        path.addArc(tangent1End: CGPoint(x: 18, y: 18), tangent2End: CGPoint(x: 82, y: 18), radius: radius)
        path.addArc(tangent1End: CGPoint(x: 82, y: 18), tangent2End: CGPoint(x: 82, y: 50), radius: radius)
        path.addLine(to: CGPoint(x: 82, y: 50))
        return path
    }

    /// Shaft and head are separate strokes that meet at the tip. Drawing the
    /// head as a chevron rather than a filled triangle keeps every terminal the
    /// same weight, which is what stops the mark looking top-heavy when it is
    /// scaled down.
    /// The mark with the tray dropped, for the 16pt slot. At 16 pixels the
    /// tray's two verticals are one pixel each and the counter between them and
    /// the shaft is less than one, so drawing it costs legibility and buys
    /// nothing: it renders as a grey smudge under the arrow.
    static func arrowOnlyScale() -> CGFloat { 1.25 }

    static func arrow() -> CGPath {
        let path = CGMutablePath()
        // The shaft stops well clear of the tray floor. Let the two touch and
        // their round caps fuse into one blob at small sizes.
        path.move(to: CGPoint(x: 50, y: 33))
        path.addLine(to: CGPoint(x: 50, y: 82))
        path.move(to: CGPoint(x: 36, y: 68))
        path.addLine(to: CGPoint(x: 50, y: 82))
        path.addLine(to: CGPoint(x: 64, y: 68))
        return path
    }
}

/// A superellipse — the continuous-corner shape Apple uses for app icons.
///
/// `CGPath(roundedRect:)` gives circular corners, which read as visibly
/// "rounder" than every neighbouring icon in the Dock. Exponent 5 is the usual
/// match for the platform shape.
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

/// Stroke the mark into `rect`, which is the square the glyph's 100x100 space
/// maps onto.
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

/// The full colour icon: gradient squircle, mark on top.
///
/// `detailed` is off for the 16pt and 32pt slots. At those sizes the drop
/// shadow is a grey smear a pixel wide and the top gloss is invisible, so both
/// are dropped and the mark is drawn slightly larger and heavier — the standard
/// optical correction for small icon sizes, and the reason the asset catalog
/// has separate slots for them at all.
private func renderAppIcon(pixels: Int, detailed: Bool) -> CGImage {
    let tiny = pixels <= 16
    let context = makeContext(pixels)
    let s = CGFloat(pixels) / 1024

    // The 824pt content square inside a 1024pt canvas, nudged up to leave room
    // for the shadow. This is the macOS icon grid; ignoring it makes the icon
    // sit at a different size to everything else in the Dock.
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
        // A highlight across the top third, the way a physical convex surface
        // catches light. Subtle on purpose: at 6% it reads as depth, at 20% it
        // reads as a 2010 gel button.
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
        // Arrow-only art has its ink centred on y=57 rather than y=50, so the
        // box it is drawn in has to sit lower for the mark to look centred.
        y: plate.midY - side / 2 - (tiny ? side * 0.07 : 0),
        width: side, height: side
    )
    strokeGlyph(
        in: context, rect: glyphRect, weight: weight, color: color(1, 1, 1), includeTray: !tiny
    )

    return context.makeImage()!
}

/// A menu bar template image: black ink and alpha only. macOS recolours it for
/// light, dark, and the highlighted state — supplying colour here would defeat
/// that and leave a blue smudge on a black menu bar.
///
/// There is deliberately no slashed "not receiving" variant. Every slash angle
/// tried either lay along the arrowhead's limb or along its shaft, and at 18
/// points the result was an unreadable tangle rather than a mark with a bar
/// through it. The off state is shown with `appearsDisabled` on the status
/// button instead, which is what the platform does for Bluetooth.
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

// --- AppIcon -----------------------------------------------------------------

print("AppIcon:")

/// (point size, scale). 16pt and 32pt get the simplified treatment.
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

// --- Menu bar ----------------------------------------------------------------

/// 18pt is the conventional menu bar glyph size. 1x and 2x only: macOS has no
/// 3x displays, and actool rejects a 3x child in a `mac` image set.
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

// --- Share extension header --------------------------------------------------

// The extension is a separate bundle with a separate catalog; it cannot reach
// into the container app's. This is the same colour mark at header size.
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
