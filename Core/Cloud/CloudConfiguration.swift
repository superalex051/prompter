import Foundation

/// Whether this build may use iCloud, and with which container. It only reads the build: it never touches iCloud.
///
/// iCloud is on only when the `PROMPTER_CLOUD` switch is compiled in and the app's Info.plist names a container
/// (`PrompterCloudContainer`, from `PROMPTER_CLOUD_CONTAINER` in the git-ignored Config/Store.xcconfig). Everything else is
/// off: a self-build, an unsigned script build (the scripts empty the container on purpose, because an app without the
/// iCloud entitlement must never open a container), and a value that is empty, blank, an unexpanded `$(...)` setting, or not
/// a container ID at all.
enum CloudConfiguration: Equatable, Sendable {
    case enabled(containerID: String)
    case disabled(Reason)

    enum Reason: Equatable, Sendable {
        /// The `PROMPTER_CLOUD` switch is not compiled in (a self-build, or a store build without iCloud).
        case notACloudBuild
        /// No container named, or only blanks.
        case noContainer
        /// The value still holds `$(`: a build setting that was never filled in.
        case unexpandedSetting
        /// The value is not an iCloud container ID (those start with `iCloud.`).
        case notAContainerID
    }

    /// The Info.plist key holding the container ID.
    static let infoKey = "PrompterCloudContainer"

    /// The pure rule, so tests can try every case.
    static func resolve(cloudBuild: Bool, containerValue: Any?) -> CloudConfiguration {
        guard cloudBuild else { return .disabled(.notACloudBuild) }
        let value = (containerValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty { return .disabled(.noContainer) }
        if value.contains("$(") { return .disabled(.unexpandedSetting) }
        guard value.hasPrefix("iCloud."), value.count > "iCloud.".count,
              !value.contains(where: \.isWhitespace) else { return .disabled(.notAContainerID) }
        return .enabled(containerID: value)
    }

    /// This app's configuration.
    static func current(bundle: Bundle = .main) -> CloudConfiguration {
        resolve(cloudBuild: BuildFlags.isCloudBuild, containerValue: bundle.object(forInfoDictionaryKey: infoKey))
    }

    var isEnabled: Bool {
        if case .enabled = self { return true }
        return false
    }

    var containerID: String? {
        if case .enabled(let id) = self { return id }
        return nil
    }
}
