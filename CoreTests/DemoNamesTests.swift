import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// Demo data and demo launches show neutral names: no person's name and no brand or product trademarks, because
/// screenshots and the public repository are built from them.
struct DemoNamesTests {
    private static let forbidden = ["youtube", "sony", "a7c", "netflix", "instagram", "tiktok"]

    private func expectNeutral(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let lower = text.lowercased()
        for word in Self.forbidden {
            #expect(!lower.contains(word), "\"\(text.prefix(60))\" contains \"\(word)\"", sourceLocation: sourceLocation)
        }
    }

    @Test func demoScriptsAreNeutral() {
        let scripts = DemoData.scripts(now: Date(timeIntervalSince1970: 1_800_000_000), includeMarkdown: true)
        #expect(scripts.count >= 4)
        for script in scripts {
            expectNeutral(script.title)
            expectNeutral(script.body)
        }
    }

    @Test func demoDeviceNamesAreNeutral() {
        expectNeutral(DemoData.macName)
        expectNeutral(DemoData.phoneName)
        expectNeutral(WatchLaunchOptions.DemoStatus.demoMacName)
        expectNeutral(WatchLaunchOptions.DemoStatus.demoTitle)
    }

    @Test func theWatchDemoUsesTheSameTitleAsTheDemoLibrary() {
        #expect(DemoData.scripts(now: .now).contains { $0.title == WatchLaunchOptions.DemoStatus.demoTitle })
    }
}
