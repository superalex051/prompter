#!/usr/bin/env swift
// Draws the Prompter app icons with CoreGraphics and writes them, plus Contents.json, into both asset catalogs.
//
//   swift scripts/make-icons.swift
//
// Output is deterministic: re-running reproduces the same files byte for byte.
// Apple frameworks only. Works from any directory (paths are resolved from this file's location).
//
// The mark: pure black field, four thick rounded white "text lines" of varying length (top one dimmed to 35 %,
// as if above the reading line) and a small amber (#FFB020) triangle at the left pointing at the gap between the
// dimmed line and the bright lines. About 12 % padding, centred so the watchOS circle mask does not clip it.
//
// Files written (iOS and watchOS: 1024 x 1024, 8-bit sRGB, no alpha channel, because App Store icons must be opaque):
//   iOS:     AppIcon-1024.png (any appearance), AppIcon-1024-dark.png, AppIcon-1024-tinted.png (grayscale)
//   watchOS: AppIcon-1024.png
//   macOS:   icon_16x16.png … icon_512x512@2x.png (with alpha). Mac icons aren't masked by the system the way iOS icons
//            are: the artwork itself is the rounded "squircle" (Apple's grid: an 824 x 824 body centred on the 1024
//            canvas, i.e. 100 px of transparent padding), with a soft drop shadow below it.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

func srgb(_ red: Double, _ green: Double, _ blue: Double) -> CGColor {
    CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, 1])!
}

func gray(_ value: Double) -> CGColor { srgb(value, value, value) }

struct Palette {
    let background: CGColor
    let bright: CGColor   // lines below the reading line
    let dim: CGColor      // line above the reading line
    let marker: CGColor   // the chevron at the reading line
}

// Amber #FFB020 is also the app's AccentColor.
let amber = srgb(255.0 / 255, 176.0 / 255, 32.0 / 255)

let standardPalette = Palette(background: gray(0), bright: gray(1), dim: gray(0.35), marker: amber)
// Dark appearance: the field is already black, so the artwork is the same as the standard icon.
let darkPalette = standardPalette
// Tinted appearance: grayscale only. iOS maps luminance onto the user's tint colour, so the marker is a
// light gray (roughly amber's luma) to stay distinct from the white lines and the dimmed line.
let tintedPalette = Palette(background: gray(0), bright: gray(1), dim: gray(0.35), marker: gray(0.75))

// MARK: - Geometry (design units on a 1024 x 1024 canvas)

let canvas = 1024

let lineThickness: CGFloat = 104
let lineGap: CGFloat = 72
let lineLengths: [CGFloat] = [540, 574, 440, 290]   // top line is dimmed

// Chevron (a rounded, right-pointing triangle), laid out relative to where the text lines start (x = 0).
let markerStrokeRadius: CGFloat = 12                 // rounds the corners (stroke + fill)
let markerBaseX: CGFloat = -166                      // vertical edge of the triangle, before rounding
let markerTipX: CGFloat = -48                        // tip of the triangle, before rounding
let markerHalfHeight: CGFloat = 58                   // half the triangle height, before rounding

/// Draws the icon. `scale` enlarges the composition about the canvas centre (the watch icon uses a little more).
func renderIcon(palette: Palette, scale: CGFloat) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Work in top-left-origin coordinates.
    context.translateBy(x: 0, y: CGFloat(canvas))
    context.scaleBy(x: 1, y: -1)

    context.setFillColor(palette.background)
    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Centre the whole composition (chevron + text block) on the canvas, then scale about the centre.
    let centre = CGFloat(canvas) / 2
    let textWidth = lineLengths.max()!
    let textHeight = CGFloat(lineLengths.count) * lineThickness + CGFloat(lineLengths.count - 1) * lineGap
    let left = markerBaseX - markerStrokeRadius
    let right = textWidth
    let originX = centre - (left + right) / 2           // canvas x of the text start
    let originY = centre - textHeight / 2               // canvas y of the top of the first line

    context.translateBy(x: centre, y: centre)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -centre, y: -centre)

    // Text lines, left aligned, fully rounded ends.
    for (index, length) in lineLengths.enumerated() {
        let rect = CGRect(
            x: originX, y: originY + CGFloat(index) * (lineThickness + lineGap),
            width: length, height: lineThickness)
        let path = CGPath(roundedRect: rect, cornerWidth: lineThickness / 2, cornerHeight: lineThickness / 2, transform: nil)
        context.addPath(path)
        context.setFillColor(index == 0 ? palette.dim : palette.bright)
        context.fillPath()
    }

    // Chevron, centred in the gap between the dimmed line and the first bright line.
    let gapCentreY = originY + lineThickness + lineGap / 2
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: originX + markerBaseX, y: gapCentreY - markerHalfHeight))
    triangle.addLine(to: CGPoint(x: originX + markerTipX, y: gapCentreY))
    triangle.addLine(to: CGPoint(x: originX + markerBaseX, y: gapCentreY + markerHalfHeight))
    triangle.closeSubpath()
    context.setFillColor(palette.marker)
    context.setStrokeColor(palette.marker)
    context.setLineWidth(markerStrokeRadius * 2)
    context.setLineJoin(.round)
    context.addPath(triangle)
    context.drawPath(using: .fillStroke)

    return context.makeImage()!
}

// MARK: - macOS

/// Apple's macOS icon grid on a 1024 canvas: the body is 824 x 824, centred.
let macBodyInset: CGFloat = 100

/// The squircle outline: a superellipse |x/a|^n + |y/b|^n = 1 (n = 5 is close to Apple's continuous-corner shape).
func squirclePath(in rect: CGRect, exponent: CGFloat = 5, samples: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    for index in 0..<samples {
        let theta = CGFloat(index) / CGFloat(samples) * 2 * .pi
        let cosine = cos(theta)
        let sine = sin(theta)
        let x = pow(abs(cosine), 2 / exponent) * a * (cosine < 0 ? -1 : 1)
        let y = pow(abs(sine), 2 / exponent) * b * (sine < 0 ? -1 : 1)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The Mac icon at `pixels` x `pixels`: transparent canvas, a soft shadow, the black squircle with the standard artwork
/// (the full-bleed iOS image) drawn inside it.
func renderMacIcon(artwork: CGImage, pixels: Int) -> CGImage {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let unit = CGFloat(pixels) / CGFloat(canvas)
    context.scaleBy(x: unit, y: unit)
    let body = CGRect(x: 0, y: 0, width: canvas, height: canvas).insetBy(dx: macBodyInset, dy: macBodyInset)
    let outline = squirclePath(in: body)

    // Shadow (CoreGraphics' y axis points up here, so a negative y offset falls below the icon).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 20 * unit,
                      color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(outline)
    context.setFillColor(gray(0))
    context.fillPath()
    context.restoreGState()

    // Artwork (on black, like the body), a little inside the squircle so the lines don't crowd its rounded edge.
    context.saveGState()
    context.addPath(outline)
    context.clip()
    context.setFillColor(gray(0))
    context.fill(body)
    context.draw(artwork, in: body.insetBy(dx: 48, dy: 48))
    context.restoreGState()

    // A hairline edge so the black body reads against a dark Dock.
    context.addPath(outline)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.14))
    context.setLineWidth(4)
    context.strokePath()

    return context.makeImage()!
}

// MARK: - Output

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create PNG destination for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Cannot write \(url.path)")
    }
    print("wrote \(url.path)")
}

func writeText(_ text: String, to url: URL) {
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        print("wrote \(url.path)")
    } catch {
        fatalError("Cannot write \(url.path): \(error)")
    }
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iosSet = repoRoot.appendingPathComponent("Prompter/Resources/Assets.xcassets/AppIcon.appiconset")
let watchSet = repoRoot.appendingPathComponent("PrompterWatch/Resources/Assets.xcassets/AppIcon.appiconset")
let macSet = repoRoot.appendingPathComponent("PrompterMac/Resources/Assets.xcassets/AppIcon.appiconset")

for directory in [iosSet, watchSet, macSet] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

// iPhone / iPad
writePNG(renderIcon(palette: standardPalette, scale: 1.0), to: iosSet.appendingPathComponent("AppIcon-1024.png"))
writePNG(renderIcon(palette: darkPalette, scale: 1.0), to: iosSet.appendingPathComponent("AppIcon-1024-dark.png"))
writePNG(renderIcon(palette: tintedPalette, scale: 1.0), to: iosSet.appendingPathComponent("AppIcon-1024-tinted.png"))
writeText("""
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "AppIcon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "AppIcon-1024-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", to: iosSet.appendingPathComponent("Contents.json"))

// Apple Watch (the system applies a circle mask, and the artwork is a touch larger to read at small sizes)
writePNG(renderIcon(palette: standardPalette, scale: 1.05), to: watchSet.appendingPathComponent("AppIcon-1024.png"))
writeText("""
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "watchos",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", to: watchSet.appendingPathComponent("Contents.json"))

// Mac: every size the macOS AppIcon set lists (points x scale).
let macArtwork = renderIcon(palette: standardPalette, scale: 1.0)
var macEntries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(renderMacIcon(artwork: macArtwork, pixels: points * scale), to: macSet.appendingPathComponent(name))
        macEntries.append("""
            {
              "filename" : "\(name)",
              "idiom" : "mac",
              "scale" : "\(scale)x",
              "size" : "\(points)x\(points)"
            }
        """)
    }
}
writeText("""
{
  "images" : [
\(macEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

""", to: macSet.appendingPathComponent("Contents.json"))
