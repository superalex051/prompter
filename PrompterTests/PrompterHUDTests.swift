import SwiftUI
import Testing
@testable import Prompter

/// The HUD drawn over a white backdrop (standing in for the script text scrolling underneath it).
@MainActor
struct PrompterHUDTests {
    /// Script text used to show through behind "1:10" and "140 wpm": the HUD's gradient only reached 85 % opacity. Below a
    /// short feather the strip must be pure background, so the labels are always clean.
    @Test func theStripBehindTheLabelsIsFullyOpaque() throws {
        var settings = PrompterSettings()
        settings.countdownSeconds = 0
        let engine = ScrollEngine(settings: settings)
        engine.updateLayout(ScrollEngineTests.uniform(lines: 10))
        engine.start()                          // playing: no state word in the middle of the label row
        #expect(engine.state == .playing)

        let hud = PrompterHUD(engine: engine, foreground: .white, background: .black, horizontalInset: 44, fontSize: 17)
            .frame(width: 874)
            .background(Color.white)
        let renderer = ImageRenderer(content: hud)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let pixels = try #require(Pixels(image))
        let height = image.height
        let feather = Int(PrompterHUD.feather.rounded(.up))
        let barTop = height - 10 - 3            // the 3 pt bar sits on the 10 pt bottom padding

        #expect(height < 80)                    // still a small strip on a 402 pt canvas
        for y in feather..<height {
            // The side margins, where nothing is drawn but the strip.
            #expect(pixels.isBlack(x: 10, y: y), "left margin, row \(y) of \(height)")
            #expect(pixels.isBlack(x: 863, y: y), "right margin, row \(y) of \(height)")
        }
        for y in feather..<barTop {
            // Between the time and the speed, level with them.
            #expect(pixels.isBlack(x: 437, y: y), "middle, row \(y) of \(height)")
        }
        // Above the strip it fades, so the text slides under the HUD instead of being cut off.
        #expect(!pixels.isBlack(x: 10, y: 0))
    }
}

/// An image's pixels as 8-bit RGBA.
private struct Pixels {
    let width: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    /// (0, 0) is the top-left corner.
    func isBlack(x: Int, y: Int) -> Bool {
        let offset = (y * width + x) * 4
        return bytes[offset] <= 2 && bytes[offset + 1] <= 2 && bytes[offset + 2] <= 2
    }
}
