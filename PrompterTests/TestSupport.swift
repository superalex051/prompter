import Foundation
import Synchronization
import UIKit

/// A fresh, empty directory under the system temp folder. Callers remove it when done.
func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "PrompterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A clock that only moves when a test advances it. Starts on a whole second, like the dates the store persists.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(start)
    }

    var now: Date { current.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        current.withLock { $0 += seconds }
    }
}

/// A US-Letter PDF with one page per element of `pages`; each page is a list of text lines drawn top to bottom.
/// `scanned: true` rasterises the text into an image first, so the PDF has no text layer (like a scan).
func makePDFData(pages: [[String]], scanned: Bool = false, userPassword: String? = nil) -> Data {
    let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    let format = UIGraphicsPDFRendererFormat()
    if let userPassword {
        format.documentInfo = [
            kCGPDFContextUserPassword as String: userPassword,
            kCGPDFContextOwnerPassword as String: userPassword + "-owner",
        ]
    }
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 18),
        .foregroundColor: UIColor.black,
    ]
    func drawLines(_ lines: [String]) {
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: CGPoint(x: 72, y: 72 + CGFloat(index) * 36), withAttributes: attributes)
        }
    }

    return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { context in
        for lines in pages {
            context.beginPage()
            if scanned {
                let imageFormat = UIGraphicsImageRendererFormat()
                imageFormat.scale = 1
                let image = UIGraphicsImageRenderer(size: bounds.size, format: imageFormat).image { imageContext in
                    UIColor.white.setFill()
                    imageContext.fill(bounds)
                    drawLines(lines)
                }
                image.draw(in: bounds)
            } else {
                drawLines(lines)
            }
        }
    }
}
