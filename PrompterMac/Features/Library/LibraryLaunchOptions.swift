import Foundation

/// Debug launch arguments for the library and Settings windows (screenshots and checks). They are parsed on their own,
/// so `MacLaunchOptions` (and the prompter's `-route prompter`) stay out of the way; a route this type doesn't know
/// is just the library.
///
/// - `-route settings` opens the Settings window on launch; `-settingsTab general|text|teleprompter|library|help|iphone`
///   picks its tab.
/// - `-route deleted` deletes the second script, so the Undo banner is showing.
/// - `-emptyLibrary` (with `-demoData`) starts with no scripts at all.
struct LibraryLaunchOptions: Equatable, Sendable {
    enum Route: Equatable, Sendable {
        case library
        case settings
        case deleted
    }

    var route: Route = .library
    var settingsTab: MacSettingsTab = .general
    var emptyLibrary = false

    init(arguments: [String] = LaunchArguments.process) {
        switch LaunchArguments.value(after: "route", in: arguments)?.lowercased() {
        case "settings": route = .settings
        case "deleted": route = .deleted
        default: route = .library
        }
        if let name = LaunchArguments.value(after: "settingsTab", in: arguments),
           let tab = MacSettingsTab(rawValue: name.lowercased()) {
            settingsTab = tab
        }
        emptyLibrary = LaunchArguments.flag("emptyLibrary", in: arguments)
    }
}
