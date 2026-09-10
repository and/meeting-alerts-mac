// Generates MeetingsAlert's app icon from the design handoff (direction 1c, "Next block").
//
// Every dimension is a fraction of the tile edge S, per the handoff's Geometry table,
// so the artwork regenerates exactly at any raster size. Usage:
//
//     swift scripts/make-icon.swift <output.iconset>
//
// The tile is inset inside the canvas to Apple's icon grid (824/1024) rather than
// bleeding to the edge; the canvas outside the squircle stays transparent.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Handoff constants

let gridFraction: CGFloat = 0.56          // grid area, centered on the tile
let cornerFraction: CGFloat = 0.225       // macOS squircle radius
let appleGridInset: CGFloat = 824.0 / 1024.0

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

/// Detail tier. The handoff thickens and simplifies the mark below 48px so it
/// survives rasterization, and drops the neutral block entirely at 16px.
enum Tier {
    case full, simplified, minimal
    static func forSize(_ px: Int) -> Tier {
        if px <= 16 { return .minimal }
        if px <= 48 { return .simplified }
        return .full
    }
}

/// CSS gradient geometry: 0deg points to the top, angles run clockwise, y is down.
func gradientPoints(angleDeg: CGFloat, in rect: CGRect) -> (CGPoint, CGPoint) {
    let a = angleDeg * .pi / 180
    let dir = CGVector(dx: sin(a), dy: -cos(a))
    let length = abs(rect.width * sin(a)) + abs(rect.height * cos(a))
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return (CGPoint(x: center.x - dir.dx * length / 2, y: center.y - dir.dy * length / 2),
            CGPoint(x: center.x + dir.dx * length / 2, y: center.y + dir.dy * length / 2))
}

func fillGradient(_ ctx: CGContext, rect: CGRect, angle: CGFloat, stops: [(CGColor, CGFloat)]) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: stops.map { $0.0 } as CFArray,
                              locations: stops.map { $0.1 })!
    let (start, end) = gradientPoints(angleDeg: angle, in: rect)
    ctx.drawLinearGradient(gradient, start: start, end: end,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// MARK: - Drawing

func drawIcon(canvas: Int) -> CGImage {
    let px = CGFloat(canvas)
    let tier = Tier.forSize(canvas)

    let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // Flip to the handoff's coordinate system: origin top-left, y increasing downward.
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: 1, y: -1)

    let s = (px * appleGridInset).rounded()
    let tile = CGRect(x: ((px - s) / 2).rounded(), y: ((px - s) / 2).rounded(), width: s, height: s)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: cornerFraction * s,
                          cornerHeight: cornerFraction * s, transform: nil)

    // --- tile ---------------------------------------------------------------
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    if tier == .full {
        fillGradient(ctx, rect: tile, angle: 176,
                     stops: [(srgb(0x373433), 0), (srgb(0x201e1d), 0.46), (srgb(0x151312), 1)])
    } else {
        fillGradient(ctx, rect: tile, angle: 176,
                     stops: [(srgb(0x373433), 0), (srgb(0x181615), 1)])
    }

    if tier == .full {
        // Top light and bottom shade: one hairline each, clipped to the squircle.
        let hair = 0.006 * s
        ctx.setFillColor(srgb(0xffffff, 0.22))
        ctx.fill(CGRect(x: tile.minX, y: tile.minY, width: tile.width, height: hair))
        ctx.setFillColor(srgb(0x000000, 0.5))
        ctx.fill(CGRect(x: tile.minX, y: tile.maxY - hair, width: tile.width, height: hair))
        ctx.restoreGState()

        // Sheen: a separate inset squircle, so it does not ride the tile's edge.
        let sheen = tile.insetBy(dx: 0.012 * s, dy: 0.012 * s)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: sheen, cornerWidth: 0.215 * s, cornerHeight: 0.215 * s, transform: nil))
        ctx.clip()
        fillGradient(ctx, rect: sheen, angle: 180,
                     stops: [(srgb(0xffffff, 0.07), 0), (srgb(0xffffff, 0), 0.42)])
    }
    ctx.restoreGState()

    // --- grid ---------------------------------------------------------------
    let g = gridFraction * s
    let gx = tile.minX + (s - g) / 2
    let gy = tile.minY + (s - g) / 2

    let ruleCount = (tier == .full) ? 4 : (tier == .simplified ? 3 : 2)
    let ruleH = (tier == .full ? 0.016 : 0.028) * s
    ctx.setFillColor(tier == .full ? srgb(0x6e6a69) : srgb(0x7d7979))
    for i in 0..<ruleCount {
        let t = ruleCount == 1 ? 0 : CGFloat(i) * (g - ruleH) / CGFloat(ruleCount - 1)
        ctx.fill(CGRect(x: gx, y: gy + t, width: g, height: ruleH))
    }

    // --- blocks (drawn over the rules) --------------------------------------
    if tier != .minimal {
        let n = (tier == .full)
            ? CGRect(x: 0.14 * s, y: 0.032 * s, width: 0.28 * s, height: 0.114 * s)
            : CGRect(x: 0.14 * s, y: 0.028 * s, width: 0.28 * s, height: 0.100 * s)
        let neutral = n.offsetBy(dx: gx, dy: gy)
        if tier == .full {
            ctx.saveGState()
            ctx.clip(to: neutral)
            fillGradient(ctx, rect: neutral, angle: 180, stops: [(srgb(0x6e6a69), 0), (srgb(0x565251), 1)])
            ctx.setFillColor(srgb(0xffffff, 0.22))
            ctx.fill(CGRect(x: neutral.minX, y: neutral.minY, width: neutral.width, height: 0.004 * s))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(srgb(0x6e6a69))
            ctx.fill(neutral)
        }
    }

    let a = (tier == .full)
        ? CGRect(x: 0.14 * s, y: 0.212 * s, width: 0.42 * s, height: 0.192 * s)
        : CGRect(x: 0.14 * s, y: 0.224 * s, width: 0.42 * s, height: 0.168 * s)
    let accent = a.offsetBy(dx: gx, dy: gy)
    if tier == .full {
        ctx.saveGState()
        // CG's blur is roughly half the CSS blur radius.
        ctx.setShadow(offset: CGSize(width: 0, height: 0.008 * s),
                      blur: 0.016 * s * 0.5, color: srgb(0x000000, 0.45))
        ctx.setFillColor(srgb(0xec3013))
        ctx.fill(accent)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: accent)
        fillGradient(ctx, rect: accent, angle: 180,
                     stops: [(srgb(0xff4526), 0), (srgb(0xec3013), 0.60), (srgb(0xcf2409), 1)])
        ctx.setFillColor(srgb(0xffffff, 0.35))
        ctx.fill(CGRect(x: accent.minX, y: accent.minY, width: accent.width, height: 0.004 * s))
        ctx.restoreGState()
    } else {
        ctx.setFillColor(srgb(0xec3013))
        ctx.fill(accent)
    }

    return ctx.makeImage()!
}

// MARK: - Export

let members: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

for (name, size) in members {
    let image = drawIcon(canvas: size)
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: out.appendingPathComponent(name))
    print("  \(name) (\(size)px)")
}
