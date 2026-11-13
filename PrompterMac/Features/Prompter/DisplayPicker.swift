import CoreGraphics
import Foundation

/// One connected screen, as the display picker sees it (built from `NSScreen` by `ScreenCatalog`; plain values so the
/// picking rules can be tested without screens).
struct DisplayDescriptor: Equatable, Sendable, Identifiable {
    /// `CGDirectDisplayID`. Stable while the screen stays connected; may change when it is plugged in again.
    var id: UInt32
    /// `NSScreen.localizedName`, e.g. "LG HDR 4K" or "Built-in Retina Display".
    var name: String
    /// In global screen coordinates (points).
    var frame: CGRect
    /// The laptop's own panel.
    var isBuiltIn: Bool
    /// The primary screen (`NSScreen.screens[0]`), the one with the menu bar and the Dock by default.
    var hasMenuBar: Bool

    /// "2560 × 1440": the screen's size in points, which is the resolution macOS shows in System Settings → Displays.
    var resolutionText: String {
        "\(Int(frame.width.rounded())) × \(Int(frame.height.rounded()))"
    }
}

/// The output screen the person picked last, remembered by ID and name (the ID can change when a screen is plugged in
/// again, the name usually doesn't).
struct RememberedOutput: Codable, Equatable, Sendable {
    var displayID: UInt32
    var name: String
}

/// `-outputScreen <index|name>`: a screen by its index in `NSScreen.screens` or by (part of) its name.
enum OutputScreenRequest: Equatable, Sendable {
    case index(Int)
    case name(String)

    init?(argument: String) {
        let trimmed = argument.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let index = Int(trimmed) {
            self = .index(index)
        } else {
            self = .name(trimmed)
        }
    }
}

/// Where the prompter output and the Presenter view go. The same screen for both means a single-screen setup: the output
/// is then an ordinary window beside the Presenter view, unless `outputStaysFullScreen`.
struct DisplayPlan: Equatable, Sendable {
    var output: DisplayDescriptor.ID
    var presenter: DisplayDescriptor.ID
    /// The Presenter view's screen went away (a laptop's lid closed mid-take) and only the teleprompter screen is left:
    /// the output keeps filling it, and the Presenter view waits as an ordinary window behind it (the keys still work).
    var outputStaysFullScreen = false

    var isSingleScreen: Bool { output == presenter }
}

/// The rules for choosing the output (teleprompter) screen and the Presenter view's screen. Pure.
enum DisplayPicker {
    /// The plan for `screens` (in `NSScreen.screens` order). The output screen is, in order of preference: the one
    /// `request` names; the remembered one, if it is connected; otherwise an automatic choice (`automaticOutput`).
    /// nil only when there are no screens.
    static func plan(
        screens: [DisplayDescriptor],
        request: OutputScreenRequest? = nil,
        remembered: RememberedOutput? = nil
    ) -> DisplayPlan? {
        guard !screens.isEmpty else { return nil }
        let output = request.flatMap { screen(for: $0, in: screens) }
            ?? remembered.flatMap { match($0, in: screens) }
            ?? automaticOutput(in: screens)
        return DisplayPlan(output: output.id, presenter: presenterScreen(forOutput: output.id, in: screens))
    }

    /// An external screen rather than the laptop's own, and preferably not the one with the menu bar (where the Presenter
    /// view goes). With one screen, that screen.
    static func automaticOutput(in screens: [DisplayDescriptor]) -> DisplayDescriptor {
        screens.first { !$0.isBuiltIn && !$0.hasMenuBar }
            ?? screens.first { !$0.isBuiltIn }
            ?? screens.first { !$0.hasMenuBar }
            ?? screens[0]
    }

    /// The Presenter view's screen for a given output: the laptop's own screen, else the menu-bar screen, else any other
    /// screen; the output's own screen only when it is the only one.
    static func presenterScreen(forOutput output: DisplayDescriptor.ID, in screens: [DisplayDescriptor]) -> DisplayDescriptor.ID {
        let others = screens.filter { $0.id != output }
        let choice = others.first(where: \.isBuiltIn) ?? others.first(where: \.hasMenuBar) ?? others.first
        return choice?.id ?? output
    }

    /// The remembered screen if it is connected: the same ID and name, else the only screen with that name.
    static func match(_ remembered: RememberedOutput, in screens: [DisplayDescriptor]) -> DisplayDescriptor? {
        if let exact = screens.first(where: { $0.id == remembered.displayID && $0.name == remembered.name }) {
            return exact
        }
        let named = screens.filter { $0.name == remembered.name }
        return named.count == 1 ? named[0] : nil
    }

    /// The screen a `-outputScreen` request names: an index into `screens`, or the first screen whose name contains the
    /// text (any case). nil if none does.
    static func screen(for request: OutputScreenRequest, in screens: [DisplayDescriptor]) -> DisplayDescriptor? {
        switch request {
        case .index(let index):
            return screens.indices.contains(index) ? screens[index] : nil
        case .name(let name):
            return screens.first { $0.name.localizedCaseInsensitiveContains(name) }
        }
    }

    /// The person picked `output` for the prompter. If that is the Presenter view's screen, the two swap; otherwise the
    /// Presenter view stays where it is (or moves off the output's screen if it has to).
    static func choosing(output: DisplayDescriptor.ID, from plan: DisplayPlan, in screens: [DisplayDescriptor]) -> DisplayPlan {
        guard screens.contains(where: { $0.id == output }) else { return plan }
        if output == plan.presenter, !plan.isSingleScreen {
            return DisplayPlan(output: output, presenter: plan.output)
        }
        let presenter = plan.presenter != output && screens.contains(where: { $0.id == plan.presenter })
            ? plan.presenter
            : presenterScreen(forOutput: output, in: screens)
        return DisplayPlan(output: output, presenter: presenter)
    }

    /// The output and the Presenter view trade screens (nothing changes on a single screen).
    static func swapped(_ plan: DisplayPlan) -> DisplayPlan {
        DisplayPlan(output: plan.presenter, presenter: plan.output)
    }

    /// What to do when screens connect or disconnect while presenting.
    struct Replan: Equatable, Sendable {
        var plan: DisplayPlan
        /// The output's screen went away: the take should pause (the text must not scroll on where nobody sees it).
        var outputLost: Bool
        /// The Presenter view's screen went away (a laptop's lid closed): the take should pause too, since the person
        /// has just lost the controls and the timing.
        var presenterLost = false

        /// The take should pause.
        var isDisruptive: Bool { outputLost || presenterLost }
    }

    /// Both screens still there: the plan stands, unless it was a single-screen plan and a second screen has appeared
    /// (then the output moves to the screen a fresh plan picks). The output's screen gone: a fresh plan, `outputLost`.
    /// Only the Presenter view's screen gone (`presenterLost`): it moves to another screen if there is one; if only the
    /// output's screen is left, the output stays full screen there and the Presenter view goes behind it
    /// (`outputStaysFullScreen`). nil when no screens are left.
    static func replan(
        current: DisplayPlan,
        screens: [DisplayDescriptor],
        remembered: RememberedOutput? = nil
    ) -> Replan? {
        guard !screens.isEmpty else { return nil }
        let ids = Set(screens.map(\.id))
        guard ids.contains(current.output) else {
            guard let fresh = plan(screens: screens, remembered: remembered) else { return nil }
            return Replan(plan: fresh, outputLost: true)
        }
        if current.isSingleScreen, screens.count > 1, let fresh = plan(screens: screens, remembered: remembered) {
            return Replan(plan: fresh, outputLost: false)
        }
        if !ids.contains(current.presenter) {
            let presenter = presenterScreen(forOutput: current.output, in: screens)
            return Replan(
                plan: DisplayPlan(output: current.output, presenter: presenter, outputStaysFullScreen: presenter == current.output),
                outputLost: false,
                presenterLost: true
            )
        }
        return Replan(plan: current, outputLost: false)
    }
}
