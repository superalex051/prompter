import Foundation
import Testing
#if os(macOS)
@testable import PrompterMac
#else
@testable import Prompter
#endif

/// The build's switches (Config/Signing.xcconfig, and Config/Store.xcconfig in the Store configurations) reach the code.
/// Runs on both platforms in every configuration: plain Debug and Release are self-builds, Store Debug and Store Release
/// are store builds.
struct BuildFlagsTests {
    @Test func compiledSwitchesMatchTheBuildSetting() {
        // The Info key is $(PROMPTER_FLAGS) and the Swift conditions are [DEBUG] $(PROMPTER_FLAGS). They differ only when a
        // target overrides the conditions or the Info key went missing.
        #expect(BuildFlags.compiled == BuildFlags.declared(in: .main))
    }

    @Test func everyDeclaredSwitchIsKnown() {
        #expect(BuildFlags.declared(in: .main).isSubset(of: BuildFlags.known))
    }

    @Test func theTestsSeeTheSameSwitchesAsTheApp() {
        // The test targets compile CoreTests themselves, so their conditions must come from the same project-level setting.
        var seen: Set<String> = []
        #if PROMPTER_STORE
        seen.insert(BuildFlags.store)
        #endif
        #if PROMPTER_CLOUD
        seen.insert(BuildFlags.cloud)
        #endif
        #expect(seen == BuildFlags.compiled)
    }

    @Test func noStoreSwitchMeansProIsOn() {
        #expect(BuildFlags.unlocksProWithoutPurchase == !BuildFlags.isStoreBuild)
        if !BuildFlags.isCloudBuild {
            #expect(CloudConfiguration.current() == .disabled(.notACloudBuild))
        }
    }

    @Test func readsTheInfoValue() {
        #expect(BuildFlags.declared(nil).isEmpty)
        #expect(BuildFlags.declared("").isEmpty)
        #expect(BuildFlags.declared("   ").isEmpty)
        #expect(BuildFlags.declared(42).isEmpty)
        #expect(BuildFlags.declared(" PROMPTER_STORE  PROMPTER_CLOUD ") == [BuildFlags.store, BuildFlags.cloud])
        #expect(BuildFlags.declared("PROMPTER_STORE") == [BuildFlags.store])
    }

    /// The test scripts say which kind of build they made (TEST_RUNNER_PROMPTER_EXPECTED_BUILD reaches the app as
    /// PROMPTER_EXPECTED_BUILD). The checks above hold for any build, so without this a Store lane that quietly became a
    /// self-build (no Config/Store.xcconfig) would pass.
    @Test func isTheBuildTheScriptAskedFor() {
        let expected = ProcessInfo.processInfo.environment["PROMPTER_EXPECTED_BUILD"] ?? ""
        // scripts/check-selfbuild.sh looks for this line to prove the expectation reached the test.
        print("BuildFlagsTests: expected build '\(expected)', switches \(BuildFlags.compiled.sorted())")
        switch expected {
        case "":
            return  // a run from Xcode, which says nothing
        case "selfbuild":
            #expect(BuildFlags.compiled.isEmpty)
            #expect(BuildFlags.unlocksProWithoutPurchase)
            #expect(CloudConfiguration.current() == .disabled(.notACloudBuild))
        case "store":
            #expect(BuildFlags.isStoreBuild)
            #expect(!BuildFlags.unlocksProWithoutPurchase)
            if BuildFlags.isCloudBuild {
                // Script builds are never team-signed, so they carry no container and iCloud stays off.
                #expect(CloudConfiguration.current() == .disabled(.noContainer))
            }
        default:
            Issue.record("Unknown PROMPTER_EXPECTED_BUILD '\(expected)' (expected selfbuild or store)")
        }
    }
}
