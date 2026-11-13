import Testing
@testable import Prompter

struct SkeletonTests {
    @Test func sharedModuleIsVisible() {
        #expect(PrompterShared.appName == "Prompter")
    }
}
