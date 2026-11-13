import AppKit

/// The connected screens as `DisplayDescriptor`s, and back from a descriptor's ID to its `NSScreen`.
@MainActor
enum ScreenCatalog {
    /// `-singleScreen`: only the main screen counts.
    static var onlyMainScreen = false

    static func descriptors(of screens: [NSScreen] = NSScreen.screens) -> [DisplayDescriptor] {
        let screens = onlyMainScreen ? Array(screens.prefix(1)) : screens
        return screens.enumerated().map { index, screen in
            let id = displayID(of: screen)
            return DisplayDescriptor(
                id: id,
                name: screen.localizedName,
                frame: screen.frame,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                hasMenuBar: index == 0
            )
        }
    }

    static func screen(withID id: DisplayDescriptor.ID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    static func displayID(of screen: NSScreen) -> UInt32 {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value ?? 0
    }
}
