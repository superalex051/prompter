import CoreGraphics
import Foundation

/// How the prompter canvas sits on the Mac's screens. Pure.
///
/// The canvas is drawn by Core Animation layers, whose coordinates on the Mac run up (y = 0 at the bottom), while the
/// iPhone's `PrompterCanvasTransform` is written for UIKit's downward y. Mirror and flip are the same either way; a
/// rotation turns the other way round, so the Mac uses the opposite quarter turn to show the same picture as the iPhone.
enum CanvasGeometry {
    /// The canvas for a screen (or window) of `screenSize`: the same size, or width and height swapped for 90°/270°,
    /// so the rotated canvas covers the screen exactly.
    static func canvasSize(screenSize: CGSize, rotation: PrompterSettings.Rotation) -> CGSize {
        PrompterCanvasTransform.isSideways(rotation)
            ? CGSize(width: screenSize.height, height: screenSize.width)
            : screenSize
    }

    /// The canvas layer's transform about its centre (anchor point 0.5, 0.5) in Core Animation's upward coordinates:
    /// the rotation, then the mirror/flip, then a uniform `scale`. On screen it gives what the iPhone shows for the
    /// same settings: mirrored left to right, upside down, 90° turning the text clockwise.
    static func layerTransform(
        rotation: PrompterSettings.Rotation,
        mirror: Bool,
        flip: Bool,
        scale: Double = 1
    ) -> CGAffineTransform {
        let upward: PrompterSettings.Rotation = switch rotation {
        case .quarter: .threeQuarters
        case .threeQuarters: .quarter
        case .none, .half: rotation
        }
        // A zero canvas size makes `make` a pure linear map about the origin, which is the layer's anchor here.
        return PrompterCanvasTransform.make(rotation: upward, mirror: mirror, flip: flip, canvasSize: .zero)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The scale at which `content` just fits inside `container` (aspect kept); 0 if either is empty.
    static func fitScale(_ content: CGSize, in container: CGSize) -> Double {
        guard content.width > 0, content.height > 0, container.width > 0, container.height > 0 else { return 0 }
        return min(container.width / content.width, container.height / content.height)
    }

    /// The preview of the output in the Presenter view: readable (no mirror, flip or rotation, the canvas fitted as it
    /// is) or "as on the teleprompter" (the output's exact transform, the screen fitted).
    static func previewTransform(
        settings: PrompterSettings,
        outputScreenSize: CGSize,
        showsAsOnTeleprompter: Bool,
        in container: CGSize
    ) -> (canvasSize: CGSize, scale: Double, transform: CGAffineTransform) {
        let canvas = canvasSize(screenSize: outputScreenSize, rotation: settings.rotation)
        if showsAsOnTeleprompter {
            let scale = fitScale(outputScreenSize, in: container)
            let transform = layerTransform(
                rotation: settings.rotation, mirror: settings.mirrorHorizontal, flip: settings.flipVertical, scale: scale
            )
            return (canvas, scale, transform)
        }
        let scale = fitScale(canvas, in: container)
        return (canvas, scale, CGAffineTransform(scaleX: scale, y: scale))
    }

    /// `position` on a whole device pixel at `pixelsPerPoint`, so the glyphs stay crisp while the text moves.
    static func pixelAligned(_ position: Double, pixelsPerPoint: Double) -> Double {
        guard pixelsPerPoint > 0, position.isFinite else { return position }
        return (position * pixelsPerPoint).rounded() / pixelsPerPoint
    }
}
