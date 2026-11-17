import XCTest
@testable import MemorAICore

/// Synthetic levels, one value per second, shaped after real calls.
private enum Level {
    static let speech: Float = 0.05       // about -26 dBFS
    static let roomNoise: Float = 0.0008  // a live mic between phrases, about -62 dBFS
    static let murmur: Float = 0.009      // typing, voices at the next desk, about -41 dBFS
    static let comfort: Float = 0.0003    // a quiet far end, about -70 dBFS
    static let zero: Float = 0            // a capture that lost its source
}

/// A conversation: the two sides take turns every `turn` seconds.
private func conversation(seconds: Int, turn: Int = 6) -> (mic: [Float], system: [Float]) {
    var mic: [Float] = [], system: [Float] = []
    for i in 0..<seconds {
        let micTurn = (i / turn) % 2 == 0
        mic.append(micTurn ? Level.speech : Level.roomNoise)
        system.append(micTurn ? Level.comfort : Level.speech)
    }
    return (mic, system)
}

final class TrackDropoutScanTests: XCTestCase {
    /// The 16.11 call: ten minutes of a normal conversation, then the far end
    /// turns into exact zero for sixteen minutes while the owner keeps
    /// talking and pausing to listen.
    func testFarEndGoingToZeroMidCallIsAGap() {
        var (mic, system) = conversation(seconds: 1580)
        for i in 607..<1580 { system[i] = Level.zero }

        let gaps = TrackDropoutDetector.scan(mic: mic, system: system)

        XCTAssertEqual(gaps.count, 1)
        let gap = try! XCTUnwrap(gaps.first)
        XCTAssertEqual(gap.role, .system)
        XCTAssertEqual(gap.start, 607, accuracy: 1)
        XCTAssertEqual(gap.end, 1580, accuracy: 1)
        XCTAssertGreaterThan(gap.otherVoiced, 400)
    }

    /// Both sides quiet at once — waiting for someone to join, reading a
    /// shared screen — is not a hole: nobody was talking.
    func testMutualSilenceIsNotAGap() {
        var (mic, system) = conversation(seconds: 600)
        for i in 200..<400 {
            mic[i] = Level.roomNoise
            system[i] = Level.zero
        }
        XCTAssertEqual(TrackDropoutDetector.scan(mic: mic, system: system), [])
    }

    /// Waiting for people to join: the far end has nothing to play, and the
    /// owner's mic picks up the room — loud enough to be well above noise,
    /// not loud enough to be someone talking into it (16.11, minutes 3–5).
    func testRoomMurmurAgainstSilentFarEndIsNotAGap() {
        let mic = [Float](repeating: Level.murmur, count: 400)
        let system = [Float](repeating: Level.zero, count: 400)
        XCTAssertEqual(TrackDropoutDetector.scan(mic: mic, system: system), [])
    }

    /// Listening to a long monologue: the mic is quiet but alive (room
    /// noise), so it is not a dead track.
    func testListeningQuietlyIsNotAMicGap() {
        let mic = [Float](repeating: Level.roomNoise, count: 600)
        let system = [Float](repeating: Level.speech, count: 600)
        XCTAssertEqual(TrackDropoutDetector.scan(mic: mic, system: system), [])
    }

    /// A microphone delivering exact zeros while the far end talks is a dead
    /// mic, not a quiet one.
    func testDeadMicWhileFarEndTalksIsAGap() {
        var (mic, system) = conversation(seconds: 400)
        for i in 100..<250 { mic[i] = Level.zero }
        let gaps = TrackDropoutDetector.scan(mic: mic, system: system)
        XCTAssertEqual(gaps.map(\.role), [.mic])
        XCTAssertEqual(gaps.first?.start ?? -1, 100, accuracy: 1)
        XCTAssertEqual(gaps.first?.end ?? -1, 250, accuracy: 1)
    }

    /// Under a minute of far-end silence is an ordinary pause even if the
    /// owner was talking through it.
    func testShortSilenceIsNotAGap() {
        var (mic, system) = conversation(seconds: 300)
        for i in 100..<140 { system[i] = Level.zero; mic[i] = Level.speech }
        XCTAssertEqual(TrackDropoutDetector.scan(mic: mic, system: system), [])
    }

    /// A system track that ends early (the capture died and nothing filled
    /// it) leaves the rest of the call as a hole.
    func testTruncatedSystemTrackIsAGap() {
        let (mic, fullSystem) = conversation(seconds: 600)
        let system = Array(fullSystem.prefix(300))
        let gaps = TrackDropoutDetector.scan(mic: mic, system: system)
        XCTAssertEqual(gaps.map(\.role), [.system])
        XCTAssertEqual(gaps.first?.start ?? -1, 300, accuracy: 1)
    }
}

final class TrackDropoutLiveTests: XCTestCase {
    /// Drive the detector second by second like the watchdog does and collect
    /// everything it says.
    private func run(
        _ detector: TrackDropoutDetector, from: Int, to: Int,
        mic: (Int) -> Float?, system: (Int) -> Float?
    ) -> [(Int, DropoutEvent)] {
        var out: [(Int, DropoutEvent)] = []
        for s in from..<to {
            let t = Double(s + 1)
            if let m = mic(s) { detector.feed(.mic, rms: m, seconds: 1, at: t) }
            if let x = system(s) { detector.feed(.system, rms: x, seconds: 1, at: t) }
            for e in detector.evaluate(now: t) { out.append((s + 1, e)) }
        }
        return out
    }

    /// Restart first, then tell the owner if the restart did not help, then
    /// say so when the far end is back — and never nag faster than allowed.
    func testRestartThenWarnThenRecover() {
        let d = TrackDropoutDetector(roles: [.mic, .system], start: 0)
        let talk: (Int) -> Float = { ($0 / 6) % 2 == 0 ? Level.speech : Level.roomNoise }
        var events = run(d, from: 0, to: 100, mic: talk, system: { _ in Level.speech })
        XCTAssertTrue(events.isEmpty, "a healthy call says nothing: \(events)")

        events = run(d, from: 100, to: 500, mic: talk, system: { _ in Level.zero })
        let restarts = events.filter { if case .restart = $0.1 { return true } else { return false } }
        let warns = events.filter { if case .warn = $0.1 { return true } else { return false } }

        // First restart 20 s into the dropout, further ones a minute apart,
        // five at most.
        XCTAssertEqual(restarts.first?.0, 120)
        XCTAssertEqual(restarts.count, 5)
        XCTAssertEqual(restarts.map(\.0), [120, 180, 240, 300, 360])
        // First warning a minute in, the next one five minutes later.
        XCTAssertEqual(warns.map(\.0), [160, 460])
        guard let firstWarn = warns.first else { return XCTFail("no warning at all") }
        if case let .warn(role, deadFor, voiced) = firstWarn.1 {
            XCTAssertEqual(role, .system)
            XCTAssertEqual(deadFor, 60, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(voiced, 15)
        } else { XCTFail() }

        events = run(d, from: 500, to: 510, mic: talk, system: { _ in Level.speech })
        guard events.count == 1 else { return XCTFail("expected one recovery, got \(events)") }
        if case let .recovered(role, deadFor) = events[0].1 {
            XCTAssertEqual(role, .system)
            XCTAssertEqual(deadFor, 400, accuracy: 1)
        } else { XCTFail("expected recovery, got \(events)") }
    }

    /// A far end that is silent while the owner is silent too never triggers
    /// anything — no restart, no notification.
    func testQuietCallStaysQuiet() {
        let d = TrackDropoutDetector(roles: [.mic, .system], start: 0)
        let events = run(d, from: 0, to: 600, mic: { _ in Level.roomNoise }, system: { _ in Level.zero })
        XCTAssertTrue(events.isEmpty, "\(events)")
    }

    /// A capture that stops delivering buffers altogether is dead too.
    func testNoBuffersAtAllCountsAsDead() {
        let d = TrackDropoutDetector(roles: [.mic, .system], start: 0)
        let talk: (Int) -> Float = { ($0 / 6) % 2 == 0 ? Level.speech : Level.roomNoise }
        _ = run(d, from: 0, to: 30, mic: talk, system: { _ in Level.speech })
        let events = run(d, from: 30, to: 120, mic: talk, system: { _ in nil })
        guard case let .restart(role, deadFor, attempt)? = events.first?.1 else {
            return XCTFail("expected a restart, got \(events)")
        }
        XCTAssertEqual(role, .system)
        XCTAssertEqual(attempt, 1)
        XCTAssertGreaterThanOrEqual(deadFor, 20)
        XCTAssertTrue(events.contains { if case .warn(.system, _, _) = $0.1 { return true } else { return false } })
    }

    /// A pause takes time out of both tracks on purpose; after it the
    /// detector starts over instead of counting the pause as silence.
    func testResetAfterPauseForgetsTheStretch() {
        let d = TrackDropoutDetector(roles: [.mic, .system], start: 0)
        let talk: (Int) -> Float = { ($0 / 6) % 2 == 0 ? Level.speech : Level.roomNoise }
        // Dead long enough for a restart before the pause...
        let before = run(d, from: 0, to: 30, mic: talk, system: { _ in Level.zero })
        XCTAssertEqual(before.count, 1, "\(before)")
        // ...and after it, nothing about that stretch is reported back.
        d.reset(at: 300)
        let events = run(d, from: 300, to: 310, mic: talk, system: { _ in Level.speech })
        XCTAssertTrue(events.isEmpty, "\(events)")
    }
}
