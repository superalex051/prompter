// The few UIKit/AppKit types the shared core needs, under one name on both platforms.
//
// Core/ compiles into the iOS app (UIKit) and the Mac app (AppKit). Code here says `PlatformFont` / `PlatformColor`;
// the iOS-only extras (UIEdgeInsets, the `…UIColor` names the iOS app has always used) sit behind `#if canImport(UIKit)`.

#if canImport(UIKit)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformFontDescriptor = UIFontDescriptor

extension UIFont {
    /// The font's default line height (TextKit's line fragment height for it).
    var prompterLineHeight: Double { lineHeight }
}
#elseif canImport(AppKit)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformFontDescriptor = NSFontDescriptor

extension NSFont {
    /// The font's default line height, as UIKit's `UIFont.lineHeight` computes it: ascender + descender + leading.
    var prompterLineHeight: Double { ascender - descender + leading }
}
#endif
