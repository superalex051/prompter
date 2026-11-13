import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

struct LogSubsystemTests {
    @Test func usesTheBundleIDItIsGiven() {
        #expect(LogSubsystem.name(bundleID: "com.example.prompter") == "com.example.prompter")
        #expect(LogSubsystem.name(bundleID: "org.studio.prompter.watchkitapp") == "org.studio.prompter.watchkitapp")
    }

    @Test func fallsBackWithoutABundleID() {
        #expect(LogSubsystem.name(bundleID: nil) == LogSubsystem.fallback)
        #expect(LogSubsystem.name(bundleID: "") == LogSubsystem.fallback)
    }

    @Test func currentFollowsTheRunningApp() {
        #expect(LogSubsystem.current == LogSubsystem.name(bundleID: Bundle.main.bundleIdentifier))
    }
}
