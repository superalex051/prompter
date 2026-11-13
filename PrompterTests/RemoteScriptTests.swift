import Foundation
import Testing
@testable import Prompter

struct RemoteScriptTests {
    typealias Step = RemoteScript.Step

    @Test func parsesThePlanExample() {
        let script = RemoteScript("start@2,pause@12,speedStep:5@14,resume@16,backToTop@30")
        #expect(script.steps == [
            Step(at: 2, command: .start),
            Step(at: 12, command: .pause),
            Step(at: 14, command: .speedStep(5)),
            Step(at: 16, command: .resume),
            Step(at: 30, command: .backToTop),
        ])
    }

    @Test func parsesEveryCommand() {
        let script = RemoteScript(
            "start@0,pause@1,resume@2,togglePlay@3,speedStep:-5@4,setSpeed:3.5@5,backToTop@6,jumpBack@7,requestStatus@8.25"
        )
        #expect(script.steps.map(\.command) == [
            .start, .pause, .resume, .togglePlay, .speedStep(-5), .setSpeed(3.5), .backToTop, .jumpBack, .requestStatus,
        ])
        #expect(script.steps.last?.at == 8.25)
    }

    @Test func toleratesSpacesAndEmptyParts() {
        let script = RemoteScript(" start @ 1 , ,pause@2,\n")
        #expect(script.steps == [Step(at: 1, command: .start), Step(at: 2, command: .pause)])
    }

    @Test func skipsInvalidParts() {
        let script = RemoteScript(
            [
                "bogus@1",           // unknown command
                "start",             // no time
                "start@",            // empty time
                "start@soon",        // not a number
                "start@-1",          // negative time
                "start@nan",
                "start@inf",
                "@3",                // no command
                "speedStep@4",       // missing amount
                "speedStep:@4",
                "speedStep:fast@4",
                "speedStep:1.5@4",   // not a whole number
                "setSpeed:nan@4",
                "setSpeed:inf@4",
                "pause:2@5",         // pause takes no argument
                "Start@6",           // names are case-sensitive
                "jumpBack@7",        // the one valid part
            ].joined(separator: ",")
        )
        #expect(script.steps == [Step(at: 7, command: .jumpBack)])
    }

    @Test func sortsByTimeKeepingTheOrderOfTies() {
        let script = RemoteScript("pause@10,start@2,speedStep:1@5,speedStep:-1@5")
        #expect(script.steps == [
            Step(at: 2, command: .start),
            Step(at: 5, command: .speedStep(1)),
            Step(at: 5, command: .speedStep(-1)),
            Step(at: 10, command: .pause),
        ])
    }

    @Test func emptyTextHasNoSteps() {
        #expect(RemoteScript("").steps.isEmpty)
        #expect(RemoteScript(",,,").steps.isEmpty)
    }

    @Test func buildsFromSteps() {
        let steps = [Step(at: 1, command: .start)]
        #expect(RemoteScript(steps: steps).steps == steps)
    }
}
