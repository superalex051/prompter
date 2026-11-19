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

    /// The prompter's window changed size, or turned, or the hinge moved. On a device that folds (iPhone Duo) this is how a
    /// fold reaches the lock: the window moving between the cover and the inner screen. Anywhere else it does nothing, so
    /// a resized iPad window or a rotated iPhone never takes this path.
    static func windowChanged(size: CGSize, isFoldable: Bool, isHingeClosed: Bool?) {
        guard isFoldable, let isHingeClosed, size.width > 0, size.height > 0 else { return }
        let scene = activeWindowScene
        let screen = PrompterOrientationPolicy.Screen.from(windowSize: size, isHingeClosed: isHingeClosed)
        apply(policy.windowChanged(to: screen, current: scene?.effectiveGeometry.interfaceOrientation), in: scene)
    }

    /// The interface orientation of the app's window scene now. The prompter puts it in what it reports to
    /// `windowChanged`, so a half turn of the inner screen (same size, other way up) still reaches the lock.
    static var interfaceOrientation: UIInterfaceOrientation? {
        activeWindowScene?.effectiveGeometry.interfaceOrientation
    }

    /// `-demoData -landscapeSide left` (screenshots): the throwaway side store starts with this side remembered, so a take
    /// opened from portrait locks to it.
    static func rememberSide(_ side: UIInterfaceOrientation) {
        guard PrompterOrientationPolicy.isLandscape(side) else { return }
        policy.lastSide = side
        sideDefaults.set(side.rawValue, forKey: lastSideKey)
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
        // A take on a foldable's inner screen can hand the remembered side back (see `windowChanged(to:current:)`), to
        // nothing if there was none.
        if policy.lastSide != loadLastSide() {
            if let side = policy.lastSide {
                sideDefaults.set(side.rawValue, forKey: lastSideKey)
            } else {
                sideDefaults.removeObject(forKey: lastSideKey)
            }
        }
        if DuoProbe.isEnabled {
            let current = scene.map { "\($0.effectiveGeometry.interfaceOrientation.rawValue)" } ?? "no scene"
            DuoProbe.log("lock \(action) · mask \(policy.mask.rawValue) · interface \(current) (1 portrait, 2 upside down, 3 landscape right, 4 landscape left)")
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
/// - On a device that folds (iPhone Duo), folding or unfolding mid-take moves the window to the other screen, and the
///   same hold of the device is a quarter turn apart on the two screens (the cover's portrait is the inner screen's
///   landscape). A lock kept as it was would turn the text 90 degrees to the presenter, so on a screen change the lock
///   moves to the orientation that keeps the text's direction (`sameDirection`). The cover follows it. The inner screen
///   doesn't follow an app's orientations (measured on the simulator; Apple says so too), so there the request is made
///   once and whatever the inner screen shows is accepted. Closing after a screen change only relaxes the lock: the
///   orientation from before the prompter belonged to the other screen.
/// - With "Landscape only" on, keeping the text's direction wins over keeping landscape: a take folded from the open
///   screen (wide, landscape left) goes on in portrait on the cover, 466 pt lines, until it closes. Keeping landscape
///   instead would turn the text a quarter turn at the fold.
/// - The side remembered for the next take comes only from locks on the cover (or a phone without a fold). The inner
///   screen ignores the lock, so the side it shows is nobody's choice, and it would mean another direction on the cover.
struct PrompterOrientationPolicy: Equatable, Sendable {
    /// Which screen of a foldable the window is on.
    enum Screen: Equatable, Sendable {
        /// The outer screen (folded), 466 x 678 on iPhone Duo.
        case cover
        /// The inner screen (open), 951 x 669.
        case inner

        /// From the window and the hinge, only asked on a foldable. A window whose short side is at least
        /// `PrompterTextStyle.largeCanvasShortSide` (the same line the text size uses) is on the inner screen; a smaller
        /// one is on the cover only while the hinge is closed. nil when the two disagree, and then the screen stays what
        /// it was: half way through a fold or an unfold (measured: the hinge reads partly open before the window moves),
        /// Split View or a pinned video on the inner screen (a smaller window, the hinge open), a device stood up half
        /// open.
        static func from(windowSize: CGSize, isHingeClosed: Bool) -> Screen? {
            if min(windowSize.width, windowSize.height) >= PrompterTextStyle.largeCanvasShortSide { return .inner }
            return isHingeClosed ? .cover : nil
        }
    }

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
    /// Foldables: the screen the window is on, and the interface orientation last seen there (nil until the window is
    /// first reported during this take).
    private(set) var screen: Screen?
    private(set) var orientationOnScreen: UIInterfaceOrientation?
    /// Foldables: the screen the prompter opened on, so closing restores only an orientation captured on this screen.
    private(set) var screenAtOpen: Screen?
    /// Foldables: the take's first report couldn't tell the screen (Split View on the inner screen, say), so the
    /// orientation from before the prompter is never restored.
    private(set) var openedOnUnknownScreen = false
    /// The remembered side when the prompter opened, handed back if the take turns out to be on the inner screen.
    private(set) var sideBeforePrompter: UIInterfaceOrientation?

    init(defaultMask: UIInterfaceOrientationMask, lastSide: UIInterfaceOrientation? = nil) {
        self.defaultMask = defaultMask
        mask = defaultMask
        self.lastSide = lastSide
    }

    /// Locked to a single orientation: a landscape side, or on a foldable whatever keeps the text's direction after a fold.
    var isLocked: Bool { mask != defaultMask }

    mutating func prompterOpened(landscapeOnly: Bool, current: UIInterfaceOrientation?) -> Action {
        // Opened twice without closing (a stray onAppear): keep the orientation from before the first open.
        guard !isPrompterOpen else { return landscapeOnlyChanged(landscapeOnly, current: current) }
        isPrompterOpen = true
        orientationBeforePrompter = current
        screenAtOpen = screen
        openedOnUnknownScreen = false
        sideBeforePrompter = lastSide
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
        let sameScreen = screen == screenAtOpen && !openedOnUnknownScreen
        screen = nil
        orientationOnScreen = nil
        screenAtOpen = nil
        openedOnUnknownScreen = false
        sideBeforePrompter = nil
        guard isLocked else { return .none }
        mask = defaultMask
        // Folded or unfolded since the prompter opened: the orientation from before was the other screen's.
        guard sameScreen else { return .refresh }
        return .rotate(before.flatMap(Self.mask(for:)) ?? .portrait)
    }

    /// Foldables: the prompter's window is now on `newScreen`, showing `current` (also when only `current` changed: the
    /// inner screen turning over with the device). On a change of screen while locked, the lock turns to the orientation
    /// that keeps the text's direction (see the type's notes); when that isn't one the app supports (upside down, on a
    /// phone), the lock stays as it was, on either screen: a mask the app doesn't support has nothing in common with its
    /// view controllers, and UIKit can answer that with an exception. The inner screen ignores the lock anyway, and the
    /// orientation it shows is still recorded, so a fold back maps from that. A nil screen (see `Screen.from`) changes
    /// nothing, not even the orientation on record, which may belong to the other screen by then.
    mutating func windowChanged(to newScreen: Screen?, current: UIInterfaceOrientation?) -> Action {
        guard let newScreen else {
            // Opened with the device open but the window small (Split View on the inner screen, say): not the closed
            // cover, so the open lock doesn't set the side either.
            if isPrompterOpen, screenAtOpen == nil, !openedOnUnknownScreen {
                openedOnUnknownScreen = true
                lastSide = sideBeforePrompter
            }
            return .none
        }
        let previous = screen
        let previousOrientation = orientationOnScreen
        screen = newScreen
        if let current, current != .unknown { orientationOnScreen = current }
        guard isPrompterOpen else { return .none }
        if screenAtOpen == nil {
            screenAtOpen = previous ?? newScreen
            // The open lock ran before the screen was known: one taken on the inner screen doesn't set the side.
            if screenAtOpen == .inner { lastSide = sideBeforePrompter }
        }
        guard let previous, newScreen != previous, isLocked, let previousOrientation,
              let target = Self.mask(for: Self.sameDirection(as: previousOrientation, from: previous, to: newScreen))
        else { return .none }
        guard defaultMask.contains(target) else { return .none }
        mask = target
        return .rotate(target)
    }

    /// The orientation on screen `to` that shows text in the same direction, for the same hold of the device, as
    /// `orientation` on screen `from`. Measured on the iPhone Duo simulator: the cover's portrait is the inner screen's
    /// landscape left, and the cover's landscape left is the inner screen's portrait upside down; the other two follow
    /// the same quarter turn.
    static func sameDirection(as orientation: UIInterfaceOrientation, from: Screen, to: Screen) -> UIInterfaceOrientation {
        guard from != to else { return orientation }
        let coverToInner: [UIInterfaceOrientation: UIInterfaceOrientation] = [
            .portrait: .landscapeLeft,
            .landscapeLeft: .portraitUpsideDown,
            .portraitUpsideDown: .landscapeRight,
            .landscapeRight: .portrait,
        ]
        if to == .inner { return coverToInner[orientation] ?? orientation }
        return coverToInner.first { $0.value == orientation }?.key ?? orientation
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
        if screen != .inner { lastSide = side }
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
