import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// A shipped (Release) build reads no debug launch arguments at all; a Debug build reads the real ones.
struct LaunchGateTests {
    @Test func processArgumentsFollowTheBuildConfiguration() {
        #if DEBUG
        #expect(LaunchArguments.process == ProcessInfo.processInfo.arguments)
        #else
        #expect(LaunchArguments.process.isEmpty)
        #endif
    }

    @Test func optionsTypesFollowTheGateByDefault() {
        // The default arguments of each options type come from the gate, so in Release none of them can be switched on,
        // whatever the process was launched with.
        #if !DEBUG
        #expect(SyncLaunchOptions() == SyncLaunchOptions(arguments: []))
        #expect(WatchLaunchOptions() == WatchLaunchOptions(arguments: []))
        #endif
        #expect(SyncLaunchOptions(arguments: ["-syncDemo"]).demo)
        #expect(!SyncLaunchOptions(arguments: []).demo)
    }
}
