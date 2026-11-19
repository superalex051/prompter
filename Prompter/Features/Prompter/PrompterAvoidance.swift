import CoreGraphics

/// Where the prompter's few fixed pieces go so an active fold or the camera never sits on them (iPhone Duo): the
/// countdown digit, the HUD's state word and the close button. Pure geometry, so it is tested without a window.
///
/// `blocks` are the reserved regions the system reports as ACTIVE, margins included: the fold only while the device is
/// partly folded (Book), the cover's camera always. Lying flat in the rig the fold is inactive, so nothing moves there,
/// and on an iPhone or iPad there are no blocks at all. Each piece makes the smallest move that clears it (Apple: move
/// only what is needed, keep things near where they were); everything else stays where it is, and the scrolling text
/// runs across the fold like any scrolling content.
enum PrompterAvoidance {
    /// Space kept between a moved piece and what it moved away from, in points.
    static let gap: CGFloat = 8

    /// A strip that crosses the whole screen one way (90 % of it or more): the fold.
    static func divider(in blocks: [CGRect], screen: CGSize) -> CGRect? {
        blocks.first { $0.height >= screen.height * 0.9 || $0.width >= screen.width * 0.9 }
    }

    /// The countdown, in screen points: the area its digit is centred in, or nil for the whole screen (no fold). With a
    /// fold, the digit goes to the larger side of it, centred there: the trailing side when they are equal (where the
    /// take goes on when the device closes, Apple's rule for book posture), the top half above a fold that runs across
    /// (in tabletop posture the top half is the one seen from a distance). The dimming behind it stays full screen.
    static func countdownArea(screen: CGSize, blocks: [CGRect]) -> CGRect? {
        guard screen.width > 0, screen.height > 0, let fold = divider(in: blocks, screen: screen) else { return nil }
        let bounds = CGRect(origin: .zero, size: screen)
        if fold.height >= screen.height * 0.9 {
            let leading = CGRect(x: 0, y: 0, width: max(fold.minX - gap, 0), height: screen.height)
            let trailing = CGRect(x: fold.maxX + gap, y: 0, width: max(screen.width - fold.maxX - gap, 0), height: screen.height)
            return (leading.width > trailing.width + 1 ? leading : trailing).intersection(bounds)
        } else {
            let top = CGRect(x: 0, y: 0, width: screen.width, height: max(fold.minY - gap, 0))
            let bottom = CGRect(x: 0, y: fold.maxY + gap, width: screen.width, height: max(screen.height - fold.maxY - gap, 0))
            return (bottom.height > top.height + 1 ? bottom : top).intersection(bounds)
        }
    }

    /// The HUD's state word ("Tap to start", "Paused"), in canvas points: how far to move it along its row so it clears
    /// every block on that row, the shorter way. `word` is where it sits unmoved; `blocks` are already in canvas points;
    /// `toScreen` maps canvas points to the screen, to break a tie towards the screen's trailing side. 0 when nothing is
    /// in the way, or when no move along the row can clear it (a block covering the whole row).
    static func wordShift(word: CGRect, row: CGRect, blocks: [CGRect], toScreen: CGAffineTransform) -> CGFloat {
        guard !word.isEmpty else { return 0 }
        let inWay = blocks.filter { overlaps($0, word.insetBy(dx: -gap, dy: 0)) }
        guard !inWay.isEmpty else { return 0 }
        // Settle on a spot that clears every block: step past whatever is in the way, in each direction.
        func settle(_ direction: CGFloat) -> CGFloat? {
            var shift: CGFloat = 0
            for _ in 0...blocks.count {
                let moved = word.offsetBy(dx: shift, dy: 0)
                guard let hit = blocks.first(where: { overlaps($0, moved.insetBy(dx: -gap, dy: 0)) }) else {
                    return row.contains(moved) ? shift : nil
                }
                shift += direction > 0 ? hit.maxX + gap - moved.minX : hit.minX - gap - moved.maxX
            }
            return nil
        }
        let options = [settle(1), settle(-1)].compactMap { $0 }
        guard let best = options.min(by: { lhs, rhs in
            if abs(abs(lhs) - abs(rhs)) > 1 { return abs(lhs) < abs(rhs) }
            return screenTrailing(word.offsetBy(dx: lhs, dy: 0), toScreen) > screenTrailing(word.offsetBy(dx: rhs, dy: 0), toScreen)
        }) else { return 0 }
        return best
    }

    /// The close button, in screen points: how far to move it from `button` so it clears every block, the shorter way of
    /// down or across (towards the middle of the screen), staying on screen. .zero when nothing is in the way.
    static func buttonOffset(button: CGRect, screen: CGSize, blocks: [CGRect]) -> CGSize {
        guard blocks.contains(where: { overlaps($0, button) }) else { return .zero }
        let bounds = CGRect(origin: .zero, size: screen)
        func settle(down: Bool) -> CGSize? {
            var offset = CGSize.zero
            for _ in 0...blocks.count {
                let moved = button.offsetBy(dx: offset.width, dy: offset.height)
                guard let hit = blocks.first(where: { overlaps($0, moved) }) else {
                    return bounds.contains(moved) ? offset : nil
                }
                if down { offset.height += hit.maxY + gap - moved.minY } else { offset.width += hit.maxX + gap - moved.minX }
            }
            return nil
        }
        let options = [settle(down: true), settle(down: false)].compactMap { $0 }
        return options.min { max($0.width, $0.height) < max($1.width, $1.height) } ?? .zero
    }

    /// The two share some area (only touching at an edge doesn't count: a piece moved a gap clear of a block touches the
    /// block's margin-widened rect exactly).
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }

    /// How far towards the screen's trailing edge (then its top) a canvas rect lands, for breaking ties.
    private static func screenTrailing(_ rect: CGRect, _ toScreen: CGAffineTransform) -> CGFloat {
        let onScreen = rect.applying(toScreen)
        return onScreen.midX - onScreen.midY / 10_000
    }
}
