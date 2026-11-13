import Foundation
import Testing
@testable import Prompter

/// The privacy manifests must declare every required-reason API the apps use. Both apps read `ProcessInfo.systemUptime`
/// (the iPhone microphone watchdog, the watch Crown batching), which is the SystemBootTime category with reason 35F9.1.
struct PrivacyManifestTests {
    private struct Manifest {
        var tracking: Bool
        var collectedTypeCount: Int
        var accessed: [String: [String]]

        init(url: URL) throws {
            let data = try Data(contentsOf: url)
            let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            tracking = plist["NSPrivacyTracking"] as? Bool ?? true
            collectedTypeCount = (plist["NSPrivacyCollectedDataTypes"] as? [Any])?.count ?? -1
            var found: [String: [String]] = [:]
            for entry in plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? [] {
                guard let type = entry["NSPrivacyAccessedAPIType"] as? String else { continue }
                found[type] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
            }
            accessed = found
        }
    }

    private func expectDeclaresBootTime(_ manifest: Manifest) {
        #expect(manifest.tracking == false)
        #expect(manifest.collectedTypeCount == 0)
        #expect(manifest.accessed["NSPrivacyAccessedAPICategorySystemBootTime"] == ["35F9.1"])
    }

    @Test func iPhoneManifestDeclaresSystemBootTime() throws {
        let url = try #require(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try Manifest(url: url)
        expectDeclaresBootTime(manifest)
        #expect(manifest.accessed["NSPrivacyAccessedAPICategoryUserDefaults"] == ["CA92.1"])
    }

    @Test func embeddedWatchAppManifestDeclaresSystemBootTime() throws {
        // The test build embeds the watch app under Watch/. A build without it is a broken setup, not a pass.
        let watchDir = Bundle.main.bundleURL.appending(path: "Watch", directoryHint: .isDirectory)
        let apps = (try? FileManager.default.contentsOfDirectory(at: watchDir, includingPropertiesForKeys: nil)) ?? []
        guard let watchApp = apps.first(where: { $0.pathExtension == "app" }) else {
            Issue.record("No embedded watch app under Watch/ in the test host build")
            return
        }
        let manifest = try Manifest(url: watchApp.appending(path: "PrivacyInfo.xcprivacy"))
        expectDeclaresBootTime(manifest)
    }

    @Test func watchSourceManifestDeclaresSystemBootTime() throws {
        // Read straight from the source tree, so this holds even when a build leaves the watch app out.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try Manifest(url: root.appending(path: "PrompterWatch/PrivacyInfo.xcprivacy"))
        expectDeclaresBootTime(manifest)
    }
}
