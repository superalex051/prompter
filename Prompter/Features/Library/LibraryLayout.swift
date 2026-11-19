import CoreGraphics

/// Which of the library's two layouts a window gets: the navigation stack (the list, with the editor pushed over it) or the
/// split view (the list on the left, the open script's editor on the right).
///
/// Regular width alone is not enough on an iPhone. The iPhone Duo's open screen is regular width in both holds, but held
/// tall it is only 669 pt wide: the split view collapsed its list behind a sidebar button there and showed an empty
/// "Pick a script" page. So a phone gets the split only when the window is also wide enough for two columns (the open
/// Duo held wide, 951 pt, or a Pro Max in landscape, about 956 pt).
///
/// The width also keeps the layout steady while the Duo unfolds: the size class turns regular a frame or two before the
/// window scene grows (the scene was still the cover's 466 pt then, the views 382 and 466 pt), which stays below the
/// minimum, so the library switches once.
///
/// An iPad keeps exactly what it had: the split whenever the width is regular, including a half-screen window narrower
/// than the phone minimum.
enum LibraryLayout: Equatable, Sendable {
    case stack
    case split

    /// The narrowest phone window that gets two columns: the sidebar's 340 pt minimum plus room for the editor.
    /// scripts/qa.sh uses the same number to pick the Duo's flows (`DUO_SPLIT_MIN_WIDTH`); change both together.
    static let minimumSplitWidth: CGFloat = 700

    /// `windowWidth`: the window's full width in points, or nil before the first layout pass (then the size class
    /// decides, as it always did).
    static func choose(isRegularWidth: Bool, windowWidth: CGFloat?, isPad: Bool) -> LibraryLayout {
        guard isRegularWidth else { return .stack }
        guard !isPad, let windowWidth else { return .split }
        return windowWidth >= minimumSplitWidth ? .split : .stack
    }
}
