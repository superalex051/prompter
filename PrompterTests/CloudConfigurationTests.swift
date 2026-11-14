import Foundation
import Testing
@testable import Prompter

/// iCloud is on only with the PROMPTER_CLOUD switch and a real container ID. Every other value keeps it off.
struct CloudConfigurationTests {
    @Test func offWithoutTheCloudSwitch() {
        #expect(CloudConfiguration.resolve(cloudBuild: false, containerValue: "iCloud.com.example.prompter")
                == .disabled(.notACloudBuild))
        #expect(CloudConfiguration.resolve(cloudBuild: false, containerValue: nil) == .disabled(.notACloudBuild))
    }

    @Test(arguments: [nil, "", " ", "\n\t "] as [String?])
    func offWithoutAContainer(value: String?) {
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: value) == .disabled(.noContainer))
    }

    @Test func offWhenTheValueIsNotText() {
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: 42) == .disabled(.noContainer))
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: ["iCloud.com.example.prompter"])
                == .disabled(.noContainer))
    }

    @Test(arguments: ["$(PROMPTER_CLOUD_CONTAINER)", "iCloud.$(BUNDLE_ID_PREFIX).prompter", "  $(X)  "])
    func offWhenTheSettingWasNeverFilledIn(value: String) {
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: value) == .disabled(.unexpandedSetting))
    }

    @Test(arguments: ["com.example.prompter", "iCloud.", "icloud.com.example.prompter", "iCloud.com.example prompter"])
    func offForAValueThatIsNotAContainerID(value: String) {
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: value) == .disabled(.notAContainerID))
    }

    @Test func onWithTheSwitchAndAContainer() {
        let config = CloudConfiguration.resolve(cloudBuild: true, containerValue: "iCloud.com.example.prompter.dev")
        #expect(config == .enabled(containerID: "iCloud.com.example.prompter.dev"))
        #expect(config.isEnabled)
        #expect(config.containerID == "iCloud.com.example.prompter.dev")
        // Blanks around the value don't count.
        #expect(CloudConfiguration.resolve(cloudBuild: true, containerValue: " iCloud.com.example.prompter \n")
                == .enabled(containerID: "iCloud.com.example.prompter"))
    }

    @Test func disabledHasNoContainer() {
        let config = CloudConfiguration.resolve(cloudBuild: true, containerValue: "")
        #expect(!config.isEnabled)
        #expect(config.containerID == nil)
    }

    @Test func currentReadsThisApp() {
        let value = Bundle.main.object(forInfoDictionaryKey: CloudConfiguration.infoKey)
        #expect(CloudConfiguration.current() == CloudConfiguration.resolve(cloudBuild: BuildFlags.isCloudBuild,
                                                                         containerValue: value))
    }
}
