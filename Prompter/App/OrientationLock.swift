import UIKit

/// Which interface orientations the app allows right now. The app delegate reports `mask` to UIKit.
///
/// While the prompter is open with "Landscape only" on, the interface is locked to ONE landscape side for the whole take:
/// picking the phone up and putting it down the other way round must not turn the text upside down in the glass. Turning
/// "Landscape only" off mid-take only lets the interface follow the device again; closing the prompter turns it back the way
/// it was. The rules live in `PrompterOrientationPolicy`; this applies them to the window scene and remembers the side.
@MainActor
enum OrientationLock {
    /// What the app delegate returns from `application(_:supportedInterfaceOrientationsFor:)`.
    static var mask: UIInterfaceOrientationMask { policy.mask }

    /// Info.plist's orientations: everything on iPad, all but upside down on iPhone.
    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// Where the landscape side of the last take is remembered across launches. `-demoData` points it at its throwaway
    /// suite before anything opens, so screenshots never change it.
    static var sideDefaults: UserDefaults = .standard {
        didSet { policy.lastSide = loadLastSide() }
    }

    private static let lastSideKey = "prompterLandscapeSide"
    private static var policy = PrompterOrientationPolicy(defaultMask: defaultMask, lastSide: loadLastSide())

    /// The prompter appeared: lock to one landscape side if "Landscape only" is on.
    static func prompterOpened(landscapeOnly: Bool) {
        let scene = activeWindowScene
        apply(policy.prompterOpened(landscapeOnly: landscapeOnly, current: scene?.effectiveGeometry.interfaceOrientation), in: scene)
    }

    /// "Landscape only" changed while the prompter is open. On: lock to one side now. Off: only relax the lock, so the
    /// interface follows the device from here (no forced turn back to portrait mid-take).
    static func setLandscapeOnly(_ isOn: Bool) {
        let scene = activeWindowScene
        apply(policy.landscapeOnlyChanged(isOn, current: scene?.effectiveGeometry.interfaceOrientation), in: scene)
    }

    /// The prompter went away: back to the default orientations, turning the interface back to where it was before.
    static func prompterClosed() {
        apply(policy.prompterClosed(), in: activeWindowScene)
    }

    // MARK: Private

    private static var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private static func loadLastSide() -> UIInterfaceOrientation? {
        guard let raw = sideDefaults.object(forKey: lastSideKey) as? Int,
              let side = UIInterfaceOrientation(rawValue: raw),
              PrompterOrientationPolicy.isLandscape(side) else { return nil }
        return side
    }

    private static func apply(_ action: PrompterOrientationPolicy.Action, in scene: UIWindowScene?) {
        if let side = policy.lastSide, side != loadLastSide() {
            sideDefaults.set(side.rawValue, forKey: lastSideKey)
        }
        if DuoProbe.isEnabled {
            let current = scene.map { "\($0.effectiveGeometry.interfaceOrientation.rawValue)" } ?? "no scene"
            DuoProbe.log("lock \(action) · mask \(policy.mask.rawValue) · interface \(current) (1 portrait, 2 upside down, 3 left, 4 right)")
        }
        switch action {
        case .none:
            break
        case .refresh:
            refreshSupportedOrientations(in: scene)
        case .rotate(let orientations):
            refreshSupportedOrientations(in: scene)
            // Fails harmlessly where rotation isn't possible (e.g. an iPad window in Stage Manager).
            let probing = DuoProbe.isEnabled
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                guard probing else { return }
                let text = error.localizedDescription
                Task { @MainActor in DuoProbe.log("lock request refused: \(text)") }
            }
            if DuoProbe.isEnabled, let scene {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    DuoProbe.log("lock after 0.8 s · interface \(scene.effectiveGeometry.interfaceOrientation.rawValue)")
                }
            }
        }
    }

    /// Every controller in the presentation chain re-reads its supported orientations.
    private static func refreshSupportedOrientations(in scene: UIWindowScene?) {
        guard let scene else { return }
        for window in scene.windows {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }
}

/// The prompter's orientation rules as a value, so they can be tested without a window. `OrientationLock` applies the
/// actions it returns.
///
/// - Opening with "Landscape only" on locks to ONE side: the current one if the interface is already landscape, otherwise
///   the side the last lock used (so takes in a row stay the same way up in the glass), otherwise landscape right. The
///   rotation setting is the manual correction if that side is the wrong one for the rig.
/// - Turning it off mid-take only relaxes the mask; turning it on again locks to the side the interface has then.
/// - Closing restores the orientation from before the prompter, if the interface is still locked (otherwise it already
///   follows the device).
struct PrompterOrientationPolicy: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        /// Nothing to do.
        case none
        /// The supported orientations changed; controllers re-read them. No forced rotation.
        case refresh
        /// The supported orientations changed and the interface turns to these now.
        case rotate(UIInterfaceOrientationMask)
    }

    /// Info.plist's orientations, reported whenever nothing is locked.
    let defaultMask: UIInterfaceOrientationMask
    /// What the app delegate reports.
    private(set) var mask: UIInterfaceOrientationMask
    /// The landscape side the last lock used; a lock from portrait picks it again.
    var lastSide: UIInterfaceOrientation?
    private(set) var isPrompterOpen = false
    /// The interface orientation when the prompter opened, restored when it closes.
    private(set) var orientationBeforePrompter: UIInterfaceOrientation?

    init(defaultMask: UIInterfaceOrientationMask, lastSide: UIInterfaceOrientation? = nil) {
        self.defaultMask = defaultMask
        mask = defaultMask
        self.lastSide = lastSide
    }

    /// Locked to a single landscape side.
    var isLocked: Bool { mask != defaultMask }

    mutating func prompterOpened(landscapeOnly: Bool, current: UIInterfaceOrientation?) -> Action {
        // Opened twice without closing (a stray onAppear): keep the orientation from before the first open.
        guard !isPrompterOpen else { return landscapeOnlyChanged(landscapeOnly, current: current) }
        isPrompterOpen = true
        orientationBeforePrompter = current
        return landscapeOnly ? lock(current: current) : .none
    }

    mutating func landscapeOnlyChanged(_ isOn: Bool, current: UIInterfaceOrientation?) -> Action {
        guard isPrompterOpen else { return .none }
        if isOn {
            return isLocked ? .none : lock(current: current)
        }
        guard isLocked else { return .none }
        mask = defaultMask
        return .refresh
    }

    mutating func prompterClosed() -> Action {
        guard isPrompterOpen else { return .none }
        isPrompterOpen = false
        let before = orientationBeforePrompter
        orientationBeforePrompter = nil
        guard isLocked else { return .none }
        mask = defaultMask
        return .rotate(before.flatMap(Self.mask(for:)) ?? .portrait)
    }

    /// The side to lock to: `current` if it is a landscape side, else `last` if it is one, else landscape right.
    static func landscapeSide(current: UIInterfaceOrientation?, last: UIInterfaceOrientation?) -> UIInterfaceOrientation {
        if let current, isLandscape(current) { return current }
        if let last, isLandscape(last) { return last }
        return .landscapeRight
    }

    static func isLandscape(_ orientation: UIInterfaceOrientation) -> Bool {
        orientation == .landscapeLeft || orientation == .landscapeRight
    }

    /// The single-orientation mask for `orientation`; nil for `.unknown`.
    static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .unknown: nil
        @unknown default: nil
        }
    }

    private mutating func lock(current: UIInterfaceOrientation?) -> Action {
        let side = Self.landscapeSide(current: current, last: lastSide)
        lastSide = side
        mask = Self.mask(for: side) ?? .landscapeRight
        return .rotate(mask)
    }
}

/// Reports `OrientationLock.mask` to UIKit.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
