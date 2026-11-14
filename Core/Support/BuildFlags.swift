import Foundation

/// What kind of build this is, fixed at compile time by the build configuration (Config/Signing.xcconfig).
///
/// - A self-build (plain Debug or Release, what anyone builds from the source): Pro is on without a purchase, and there is
///   no iCloud. No switch is set.
/// - A store build (Store Debug or Store Release, with the switches in the git-ignored Config/Store.xcconfig):
///   `PROMPTER_STORE` sells Pro through the App Store, `PROMPTER_CLOUD` turns on iCloud sync.
///
/// The same switches are written into the app's Info.plist as `PrompterBuildFlags`, so a test can prove the compiled
/// conditions and the build setting agree (a Store configuration that lost its switches would otherwise pass as a
/// self-build without anyone noticing).
enum BuildFlags {
    /// The Info.plist key holding the `PROMPTER_FLAGS` build setting.
    static let infoKey = "PrompterBuildFlags"
    /// Pro is sold through the App Store.
    static let store = "PROMPTER_STORE"
    /// iCloud sync for scripts and settings.
    static let cloud = "PROMPTER_CLOUD"
    /// Every switch this code knows. A new switch in `PROMPTER_FLAGS` must be added here too (a test checks).
    static let known: Set<String> = [store, cloud]

    /// True in a store build: Pro is bought, not on by default.
    static var isStoreBuild: Bool {
        #if PROMPTER_STORE
        true
        #else
        false
        #endif
    }

    /// True when iCloud sync is compiled in. It still needs a container to run: see `CloudConfiguration`.
    static var isCloudBuild: Bool {
        #if PROMPTER_CLOUD
        true
        #else
        false
        #endif
    }

    /// A self-build has Pro on without any purchase.
    static var unlocksProWithoutPurchase: Bool { !isStoreBuild }

    /// The switches compiled into this binary.
    static var compiled: Set<String> {
        var flags: Set<String> = []
        if isStoreBuild { flags.insert(store) }
        if isCloudBuild { flags.insert(cloud) }
        return flags
    }

    /// The switches a `PrompterBuildFlags` value names: space-separated, empty or missing means none.
    static func declared(_ infoValue: Any?) -> Set<String> {
        guard let text = infoValue as? String else { return [] }
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// The switches the build setting gave this app's Info.plist.
    static func declared(in bundle: Bundle) -> Set<String> {
        declared(bundle.object(forInfoDictionaryKey: infoKey))
    }
}
