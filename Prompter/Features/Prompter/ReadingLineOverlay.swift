import SwiftUI

/// The reading line: everything above it is covered by the background colour, so the text there shows at
/// `dimmedOpacity`, with a 24 pt feathered edge; small amber chevrons at both side margins point at it.
struct ReadingLineOverlay: View {
    let readingLineY: Double
    let sideInset: Double
    let dimmedOpacity: Double
    let background: Color
    /// The chevrons: the scheme's cue colour (`PrompterSettings.Scheme.cueUIColor`), so they stand out on white too.
    var markerColor: Color = .accentColor

    static let feather = 24.0

    var body: some View {
        GeometryReader { proxy in
            let feather = min(Self.feather, max(readingLineY, 0))
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(background)
                        .frame(height: max(readingLineY - feather, 0))
                    LinearGradient(colors: [background, background.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: feather)
                    Spacer(minLength: 0)
                }
                .opacity(1 - min(max(dimmedOpacity, 0), 1))

                markers(width: proxy.size.width)
            }
        }
        .accessibilityHidden(true)
    }

    private func markers(width: Double) -> some View {
        let size = min(max(sideInset * 0.4, 12), 22)
        let center = max(sideInset / 2, size / 2 + 4)
        return ZStack(alignment: .topLeading) {
            ReadingMarker(pointsRight: true)
                .frame(width: size * 0.8, height: size)
                .position(x: center, y: readingLineY)
            ReadingMarker(pointsRight: false)
                .frame(width: size * 0.8, height: size)
                .position(x: width - center, y: readingLineY)
        }
        .foregroundStyle(markerColor)
    }
}

/// A filled triangle pointing at the text.
private struct ReadingMarker: Shape {
    let pointsRight: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointsRight {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}
