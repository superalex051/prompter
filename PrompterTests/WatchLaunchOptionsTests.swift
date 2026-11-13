import Foundation
import Testing
@testable import Prompter

struct WatchLaunchOptionsTests {
    typealias Demo = WatchLaunchOptions.DemoStatus

    @Test func noArgumentsMeansNoScriptAndNoDemo() {
        let options = WatchLaunchOptions(arguments: ["/path/PrompterWatch"])
        #expect(options.remoteScript == nil)
        #expect(options.demoStatus == nil)
    }

    @Test func remoteScriptIsParsed() {
        let options = WatchLaunchOptions(arguments: ["/path/PrompterWatch", "-remoteScript", "start@3,pause@14,speedStep:5@15"])
        #expect(options.remoteScript?.steps == [
            RemoteScript.Step(at: 3, command: .start),
            RemoteScript.Step(at: 14, command: .pause),
            RemoteScript.Step(at: 15, command: .speedStep(5)),
        ])
        #expect(options.demoStatus == nil)
    }

    @Test func negativeSpeedStepsArePartOfTheScript() {
        // The value starts with a command name, so a "-" inside it doesn't make it look like another option.
        let options = WatchLaunchOptions(arguments: ["-remoteScript", "speedStep:-5@1"])
        #expect(options.remoteScript?.steps == [RemoteScript.Step(at: 1, command: .speedStep(-5))])
    }

    @Test func scriptWithoutValidStepsIsNil() {
        #expect(WatchLaunchOptions(arguments: ["-remoteScript", "bogus@1,start"]).remoteScript == nil)
        #expect(WatchLaunchOptions(arguments: ["-remoteScript", ""]).remoteScript == nil)
    }

    @Test func missingValuesAreIgnored() {
        #expect(WatchLaunchOptions(arguments: ["-remoteScript"]).remoteScript == nil)
        #expect(WatchLaunchOptions(arguments: ["-demoStatus"]).demoStatus == nil)
        let options = WatchLaunchOptions(arguments: ["-remoteScript", "-demoStatus", "paused"])
        #expect(options.remoteScript == nil)
        #expect(options.demoStatus == .paused)
    }

    @Test(arguments: [
        ("ready", Demo.ready), ("countdown", .countdown), ("playing", .playing), ("paused", .paused),
        ("finished", .finished), ("unreachable", .unreachable), ("noPrompter", .noPrompter), ("NOPROMPTER", .noPrompter),
        ("Playing", .playing),
    ])
    func demoStatusNames(name: String, expected: Demo) {
        #expect(WatchLaunchOptions(arguments: ["-demoStatus", name]).demoStatus == expected)
    }

    @Test func unknownDemoStatusIsNil() {
        #expect(WatchLaunchOptions(arguments: ["-demoStatus", "dancing"]).demoStatus == nil)
    }

    @Test func bothOptionsTogether() {
        let options = WatchLaunchOptions(arguments: ["-demoStatus", "ready", "-remoteScript", "start@1"])
        #expect(options.demoStatus == .ready)
        #expect(options.remoteScript?.steps.count == 1)
    }

    @Test func undashedNamesAreNotOptions() {
        let options = WatchLaunchOptions(arguments: ["demoStatus", "ready", "remoteScript", "start@1"])
        #expect(options == WatchLaunchOptions(arguments: []))
    }
}

struct WatchDemoStatusTests {
    typealias Demo = WatchLaunchOptions.DemoStatus

    @Test(arguments: Demo.allCases)
    func everyDemoRendersItsState(demo: Demo) {
        let model = RemoteDisplayModel(status: demo.status, isReachable: demo.isReachable)
        switch demo {
        case .ready:
            #expect(model.stateText == "Ready")
            #expect(model.primaryCommand == .start)
        case .countdown:
            #expect(model.stateText == "3")
            #expect(model.countdownDigit == 3)
            #expect(model.primarySymbol == "xmark")
        case .playing:
            #expect(model.stateText == "Playing")
            #expect(model.primaryCommand == .pause)
            #expect(model.progress > 0 && model.progress < 1)
        case .paused:
            #expect(model.stateText == "Paused")
            #expect(model.primaryCommand == .resume)
        case .finished:
            #expect(model.stateText == "Finished")
            #expect(model.progress == 1)
            #expect(model.timeText == "0:00")
        case .unreachable:
            #expect(model.stateText == RemoteDisplayModel.unreachableText)
        case .noPrompter:
            #expect(model.stateText == RemoteDisplayModel.noPrompterText)
        case .macPlaying:
            #expect(model.stateText == "Playing")
            #expect(model.deviceText == "On \(Demo.demoMacName)")
        case .phoneBackground:
            #expect(model.stateText == "iPhone app in the background")
        }
        if demo != .macPlaying { #expect(model.deviceText == nil) }
        let isLive = demo != .unreachable && demo != .noPrompter && demo != .phoneBackground
        #expect(model.controlsEnabled == isLive)
        if isLive {
            #expect(model.title == Demo.demoTitle)
            #expect(!model.speedLabel.isEmpty)
        }
    }
}
