#!/usr/bin/env swift
// Renders the Chess Best Move app icon (docs/design.md section 13, "The knight's L") into
// App/Resources/Assets.xcassets/AppIcon.appiconset: the default 1024 x 1024 icon plus the
// dark and tinted appearance variants, and the set's Contents.json.
//
// Usage (from the repository root):
//   swift App/Scripts/render-app-icon.swift [output directory] [--preview <directory>]
//
// --preview also writes downscaled copies (180, 120, 80, 58 and 40 px) and a strip of them,
// to check that the hatching and the arrow survive small sizes.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants

let canvasSize = 1024
/// One square of the 3 x 3 board fragment.
let square = CGFloat(canvasSize) / 3

/// Arrow proportions in units of the square side. They follow design.md section 7, with a
/// thicker shaft and a larger head so the L reads at 29 pt.
enum Arrow {
    static let shaftWidth: CGFloat = 0.26
    static let tailOffset: CGFloat = 0.30
    static let tipInset: CGFloat = 0.10
    static let headLength: CGFloat = 0.50
    static let headWidth: CGFloat = 0.66
    static let halo: CGFloat = 0.05
}

/// Hatching of the dark squares: diagonal ink lines. The spacing stays well above the 20 px
/// minimum so downscaling to 40 px does not produce moire.
enum Hatch {
    static let spacing: CGFloat = 30
    static let lineWidth: CGFloat = 8
}

struct RGB {
    var red: CGFloat, green: CGFloat, blue: CGFloat

    init(_ hex: UInt32) {
        red = CGFloat((hex >> 16) & 0xFF) / 255
        green = CGFloat((hex >> 8) & 0xFF) / 255
        blue = CGFloat(hex & 0xFF) / 255
    }

    init(gray: CGFloat) {
        red = gray; green = gray; blue = gray
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

struct IconStyle {
    var fileName: String
    /// Paper field; also the halo color, so the halo reads as a gap in the hatching.
    var field: RGB
    var hatch: RGB
    var arrow: RGB
}

let styles: [(style: IconStyle, appearance: String?)] = [
    // Light: paper, ink hatching, cobalt arrow.
    (IconStyle(fileName: "AppIcon-1024.png", field: RGB(0xF3F0E8), hatch: RGB(0x17150F), arrow: RGB(0x2350E6)), nil),
    // Dark: ink field, dim hatching, light cobalt arrow.
    (IconStyle(fileName: "AppIcon-1024-dark.png", field: RGB(0x12110E), hatch: RGB(0x2D2A24), arrow: RGB(0x7C94FF)), "dark"),
    // Tinted: single-channel artwork, hatching at 35% luminance, arrow at 100%.
    (IconStyle(fileName: "AppIcon-1024-tinted.png", field: RGB(gray: 0), hatch: RGB(gray: 0.35), arrow: RGB(gray: 1)), "tinted"),
]

// MARK: - Drawing

/// Cells (column, row from the top). Dark squares are the corners and the center, so the
/// bottom-left square, like a1, is dark and the knight lands on a light square.
func isDark(column: Int, row: Int) -> Bool {
    (column + row).isMultiple(of: 2)
}

func center(column: Int, row: Int) -> CGPoint {
    CGPoint(x: (CGFloat(column) + 0.5) * square, y: (CGFloat(row) + 0.5) * square)
}

/// The arrow outline: an L from the bottom-left square up two squares and one to the right,
/// ending in a sharp head in the top-middle square. Coordinates have a top-left origin.
func arrowOutline() -> CGPath {
    let from = center(column: 0, row: 2)
    let corner = center(column: 0, row: 0)
    let to = center(column: 1, row: 0)

    let tail = CGPoint(x: from.x, y: from.y - Arrow.tailOffset * square)
    let tip = CGPoint(x: to.x - Arrow.tipInset * square, y: to.y)
    let headBaseX = tip.x - Arrow.headLength * square
    // The shaft runs a little into the head so the union has no seam.
    let shaftEnd = CGPoint(x: headBaseX + 0.03 * square, y: to.y)

    let shaft = CGMutablePath()
    shaft.move(to: tail)
    shaft.addLine(to: corner)
    shaft.addLine(to: shaftEnd)
    let shaftOutline = shaft.copy(strokingWithWidth: Arrow.shaftWidth * square, lineCap: .butt, lineJoin: .round, miterLimit: 10)

    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: headBaseX, y: tip.y - Arrow.headWidth * square / 2))
    head.addLine(to: CGPoint(x: headBaseX, y: tip.y + Arrow.headWidth * square / 2))
    head.closeSubpath()

    return shaftOutline.union(head)
}

func render(_ style: IconStyle) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // No alpha channel: App Store icons must be opaque.
    let context = CGContext(
        data: nil, width: canvasSize, height: canvasSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    // Top-left origin.
    context.translateBy(x: 0, y: CGFloat(canvasSize))
    context.scaleBy(x: 1, y: -1)

    let bounds = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    context.setFillColor(style.field.cgColor)
    context.fill(bounds)

    // Dark squares: diagonal hatching running from bottom left to top right, one continuous
    // pattern across the fragment.
    context.saveGState()
    for row in 0..<3 {
        for column in 0..<3 where isDark(column: column, row: row) {
            context.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
        }
    }
    context.clip()
    context.setStrokeColor(style.hatch.cgColor)
    context.setLineWidth(Hatch.lineWidth)
    context.setLineCap(.butt)
    // Lines x + y = c, spaced `Hatch.spacing` apart measured perpendicular to the lines.
    let step = Hatch.spacing * 2.squareRoot()
    var c: CGFloat = -step
    let limit = CGFloat(canvasSize) * 2 + step
    while c <= limit {
        context.move(to: CGPoint(x: c, y: 0))
        context.addLine(to: CGPoint(x: 0, y: c))
        c += step
    }
    context.strokePath()
    context.restoreGState()

    // Arrow: halo in the field color (the outline expanded by 0.05 S), then the fill.
    let outline = arrowOutline()
    context.addPath(outline)
    context.setStrokeColor(style.field.cgColor)
    context.setLineWidth(2 * Arrow.halo * square)
    context.setLineJoin(.round)
    context.strokePath()
    context.addPath(outline)
    context.setFillColor(style.arrow.cgColor)
    context.fillPath()

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "render-app-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "render-app-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot finalize \(url.path)"])
    }
}

func downscaled(_ image: CGImage, to size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

func contentsJSON() -> String {
    var entries: [String] = []
    for (style, appearance) in styles {
        var lines = ["    {"]
        if let appearance {
            lines.append("""
                      "appearances" : [
                        {
                          "appearance" : "luminosity",
                          "value" : "\(appearance)"
                        }
                      ],
                """)
        }
        lines.append("""
                  "filename" : "\(style.fileName)",
                  "idiom" : "universal",
                  "platform" : "ios",
                  "size" : "1024x1024"
                }
            """)
        entries.append(lines.joined(separator: "\n"))
    }
    return """
        {
          "images" : [
        \(entries.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
}

// MARK: - Main

var arguments = Array(CommandLine.arguments.dropFirst())
var previewDirectory: URL?
if let index = arguments.firstIndex(of: "--preview"), index + 1 < arguments.count {
    previewDirectory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    arguments.removeSubrange(index...(index + 1))
}
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let defaultOutput = scriptDirectory.appendingPathComponent("../Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true).standardized
let output = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultOutput

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var previews: [CGImage] = []
    for (style, _) in styles {
        let image = render(style)
        let url = output.appendingPathComponent(style.fileName)
        try writePNG(image, to: url)
        print("Wrote \(url.path)")
        if let previewDirectory {
            try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
            for size in [180, 120, 80, 58, 40] {
                let small = downscaled(image, to: size)
                previews.append(small)
                let name = style.fileName.replacingOccurrences(of: ".png", with: "-\(size).png")
                try writePNG(small, to: previewDirectory.appendingPathComponent(name))
            }
        }
    }
    try contentsJSON().write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("Wrote \(output.appendingPathComponent("Contents.json").path)")

    if let previewDirectory, !previews.isEmpty {
        // A strip per style: 180, 120, 80, 58, 40 px side by side on a neutral background.
        let gap = 12
        let width = [180, 120, 80, 58, 40].reduce(gap) { $0 + $1 + gap }
        let height = styles.count * (180 + gap) + gap
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (styleIndex, _) in styles.enumerated() {
            var x = gap
            let y = height - (styleIndex + 1) * (180 + gap)
            for (sizeIndex, size) in [180, 120, 80, 58, 40].enumerated() {
                let image = previews[styleIndex * 5 + sizeIndex]
                context.draw(image, in: CGRect(x: x, y: y, width: size, height: size))
                x += size + gap
            }
        }
        let strip = previewDirectory.appendingPathComponent("AppIcon-preview-strip.png")
        try writePNG(context.makeImage()!, to: strip)
        print("Wrote \(strip.path)")
    }
} catch {
    FileHandle.standardError.write(Data("render-app-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
