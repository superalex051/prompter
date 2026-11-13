import Foundation
import Testing
@testable import Prompter

struct StatusPollTests {
    /// Plays a stretch of time in the watch's 0.25 s ticks and returns when the poll asked.
    /// - `pushes`: when the phone's live messages / application contexts arrive.
    /// - `replyAfter`: how long a request's reply takes (nil: it never comes).
    static func requests(
        from start: TimeInterval = 0,
        to end: TimeInterval,
        pushes: [TimeInterval] = [],
        replyAfter: TimeInterval? = 0.8,
        expectsPushes: Bool = true,
        isReachable: Bool = true,
        poll: inout StatusPoll
    ) -> [TimeInterval] {
        var asked: [TimeInterval] = []
        var replyDue: TimeInterval?
        var pending = pushes.sorted()
        var now = start
        while now <= end {
            while let next = pending.first, next <= now {
                poll.pushArrived(now: next)
                pending.removeFirst()
            }
            if let due = replyDue, due <= now {
                poll.requestEnded()
                replyDue = nil
            }
            if poll.shouldRequest(now: now, isReachable: isReachable, expectsPushes: expectsPushes) {
                asked.append(now)
                replyDue = replyAfter.map { now + $0 }
            }
            now += 0.25
        }
        return asked
    }

    @Test func asksAtOnceWhenNothingHasArrivedYet() {
        var poll = StatusPoll()
        // (`#expect` can't call a mutating method itself.)
        let first = poll.shouldRequest(now: 100, isReachable: true, expectsPushes: false)
        // That request hasn't been answered: no second one on top of it.
        let second = poll.shouldRequest(now: 100.25, isReachable: true, expectsPushes: false)
        #expect(first)
        #expect(!second)
    }

    @Test func neverAsksWhileThePhoneIsOutOfReach() {
        var poll = StatusPoll()
        #expect(Self.requests(to: 20, isReachable: false, poll: &poll).isEmpty)
        #expect(Self.requests(to: 20, expectsPushes: false, isReachable: false, poll: &poll).isEmpty)
    }

    /// A busy device: the phone pushes up to a few statuses a second while the text moves (progress and time left).
    @Test func pushesFourTimesASecondMeanNoRequests() {
        var poll = StatusPoll()
        let pushes = stride(from: 0.0, through: 30, by: 0.25).map { $0 }
        #expect(Self.requests(to: 30, pushes: pushes, poll: &poll).isEmpty)
    }

    /// The usual case while the text moves: one push a second (the time left), on the simulators delivered in batches
    /// about once a second, sometimes a little late.
    @Test func pushesAboutOnceASecondMeanNoRequests() {
        var poll = StatusPoll()
        var pushes: [TimeInterval] = []
        var batch = 0.0
        for gap in [1.0, 1.0, 1.25, 1.0, 0.75, 1.0, 1.25, 1.0, 1.0, 1.0] {
            pushes.append(batch)
            batch += gap
        }
        #expect(Self.requests(to: batch, pushes: pushes, poll: &poll).isEmpty)
    }

    /// The bug from the M3 end-to-end run: the phone's WatchConnectivity session wrongly said the watch app wasn't
    /// installed, so it pushed nothing for the whole take, while replies to the watch's messages still came back.
    @Test func whenPushesStopItAsksOnceASecond() {
        var poll = StatusPoll()
        let pushes = stride(from: 0.0, through: 10, by: 0.25).map { $0 }
        let asked = Self.requests(to: 20, pushes: pushes, poll: &poll)
        // Quiet for 1.5 s after the last push at 10 s, then once a second.
        #expect(asked == [11.5, 12.5, 13.5, 14.5, 15.5, 16.5, 17.5, 18.5, 19.5])
    }

    @Test func aPhoneThatNeverPushesIsAskedEverySecondWhileTheTextMoves() {
        var poll = StatusPoll()
        let asked = Self.requests(to: 10, poll: &poll)
        #expect(asked == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
    }

    @Test func pushesComingBackStopTheRequests() {
        var poll = StatusPoll()
        let pushes = stride(from: 5.0, through: 20, by: 0.25).map { $0 }
        let asked = Self.requests(to: 20, pushes: pushes, poll: &poll)
        #expect(asked == [0, 1, 2, 3, 4])
    }

    @Test func oneRequestAtATimeUntilItTimesOut() {
        var poll = StatusPoll()
        // Replies never come (and no error either): a new request only once the last one counts as lost.
        let asked = Self.requests(to: 12, replyAfter: nil, poll: &poll)
        #expect(asked == [0, StatusPoll.requestTimeout, 2 * StatusPoll.requestTimeout])
    }

    @Test func aSlowReplyHoldsBackTheNextRequest() {
        var poll = StatusPoll()
        let asked = Self.requests(to: 10, replyAfter: 2.1, poll: &poll)
        // Each request waits for the reply before it (2.1 s, seen as the next 0.25 s tick).
        #expect(asked == [0, 2.25, 4.5, 6.75, 9])
    }

    /// Idle, paused or without a prompter the phone pushes nothing (nothing changes), so asking is the only way to
    /// notice a change made on the phone, but there's nothing moving to follow: every three seconds is enough.
    @Test func whileNothingMovesItAsksEveryThreeSeconds() {
        var poll = StatusPoll()
        let asked = Self.requests(to: 10, expectsPushes: false, poll: &poll)
        #expect(asked == [0, 3, 6, 9])
    }

    /// What the watch holds decides the pace: a take counting down or playing on screen is followed every second;
    /// idle, paused, finished, a prompter the phone isn't showing, none, or nothing yet every three seconds.
    @Test func onlyATakeMovingOnScreenIsFollowedLive() {
        func status(_ state: PlaybackState, onScreen: Bool = true) -> PrompterStatus {
            var status = sampleStatus
            status.state = state
            status.isOnScreen = onScreen ? nil : false
            return status
        }
        let live: [TimeInterval] = [0, 1, 2, 3, 4, 5, 6]
        let idle: [TimeInterval] = [0, 3, 6]
        let cases: [(PrompterStatus?, [TimeInterval])] = [
            (status(.countdown(3)), live),
            (status(.playing), live),
            (status(.idle), idle),
            (status(.paused), idle),
            (status(.finished), idle),
            (status(.playing, onScreen: false), idle),
            (.noPrompter, idle),
            (nil, idle),
        ]
        for (latest, expected) in cases {
            var poll = StatusPoll()
            var asked: [TimeInterval] = []
            var now = 0.0
            while now <= 6 {
                if poll.shouldRequest(now: now, isReachable: true, latest: latest) {
                    asked.append(now)
                    poll.requestEnded()
                }
                now += 0.25
            }
            #expect(asked == expected, "\(latest?.logDescription ?? "nothing yet")")
        }
    }

    @Test func aRequestSentElsewhereCounts() {
        var poll = StatusPoll()
        // The watch asks when the phone becomes reachable; the poll doesn't send a second request alongside it.
        poll.requestSent(now: 50)
        let whilePending = poll.shouldRequest(now: 50.25, isReachable: true, expectsPushes: true)
        poll.requestEnded()
        let tooSoon = poll.shouldRequest(now: 50.75, isReachable: true, expectsPushes: true)
        let aSecondLater = poll.shouldRequest(now: 51, isReachable: true, expectsPushes: true)
        #expect(!whilePending)
        #expect(!tooSoon)
        #expect(aSecondLater)
    }

    @Test func intervalsAreAboveTheGapBetweenPushes() {
        // While the text moves the phone pushes at least once a second (the time left), and the simulators deliver
        // about once a second; the poll must not mistake those gaps for silence.
        #expect(StatusPoll.quietLimit > 1.25)
        #expect(StatusPoll.liveInterval <= StatusPoll.quietLimit)
        #expect(StatusPoll.idleInterval > StatusPoll.liveInterval)
        #expect(StatusPoll.requestTimeout > StatusPoll.idleInterval)
    }
}
