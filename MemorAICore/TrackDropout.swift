import Foundation

/// One half of a call going dead while the other half keeps talking.
///
/// Why this exists: on 16.11 the far end of a 26-minute Chrome call stopped
/// reaching the system track ten minutes in. SCStream raised no error, the
/// track simply turned into exact digital zero for the remaining sixteen
/// minutes while the owner's microphone carried a normal conversation — and
/// nobody noticed until the transcript came out half empty, by which time the
/// uncompressed originals were already compressed away. The stream-error path
/// (`RecordingManager.handleStreamStopped`) cannot see this failure at all:
/// nothing stopped. Only the samples tell.
///
/// So the question asked here is not "is the far end quiet" (people are quiet
/// on calls all the time) but "is one track dead *while the other one is
/// talking*". A real conversation alternates; a track that stays at the
/// noise-free floor of a disconnected capture while the other side speaks for
/// a minute is a broken capture, not a pause.
///
/// The detector is pure: it is fed levels with timestamps and answers with
/// events. The live watchdog feeds it from the recorders' buffers, the
/// post-call audit feeds it from the files, one second at a time, and the
/// tests feed it synthetic numbers — all three get the same answer.
public enum TrackRole: String, CaseIterable, Codable, Sendable {
    case mic
    case system

    public var other: TrackRole { self == .mic ? .system : .mic }
}

/// Thresholds. Levels are linear RMS of Float32 samples (1.0 = full scale).
public struct DropoutPolicy: Sendable {
    /// Below this a track counts as dead. The system track gets a looser line
    /// than the mic: a capture that lost its source delivers exact zeros, but
    /// a far end that is merely quiet (comfort noise, a muted participant)
    /// also sits far below any speech, and the "other side is talking" rule
    /// below is what tells the two apart. A live microphone, on the other
    /// hand, always has a noise floor well above -90 dBFS.
    public var deadRMS: [TrackRole: Float]
    /// At or above this a buffer counts as speech for the *other* track's
    /// stretch. -36 dBFS: measured on the 16.11 call, a second with the
    /// owner speaking into AirPods sits at -15…-33 dBFS, while the minutes of
    /// waiting for people to join — typing, a room, voices at the next desk —
    /// sat at -38…-46. At -46 those minutes read as "talking into a dead far
    /// end" and the call's first five minutes came out as two false holes.
    public var voiceRMS: Float
    /// Restart the dead track's capture once it has been dead this long while
    /// the other side spoke for at least `restartMinOtherVoice` seconds.
    public var restartAfter: Double
    public var restartMinOtherVoice: Double
    /// Further restarts within one dead stretch, and how many at most.
    public var restartEvery: Double
    public var maxRestartsPerStretch: Int
    /// Tell the owner once a track has been dead this long while the other
    /// side spoke for at least `warnMinOtherVoice` seconds, and again every
    /// `warnEvery` seconds while it stays dead.
    public var warnAfter: Double
    public var warnMinOtherVoice: Double
    public var warnEvery: Double
    /// A stretch this long, with the other side talking at least
    /// `gapMinOtherVoice` seconds through it, is a hole in the recording.
    /// Two minutes, not one: over the October–November archive a one-minute
    /// line flagged a quarter of all calls, mostly the owner explaining
    /// something for a minute while everyone else listened in silence. The
    /// failures that cost a call were all many minutes long.
    public var gapMinSeconds: Double
    public var gapMinOtherVoice: Double
    /// No buffer for this long counts as dead too: a capture that stopped
    /// delivering altogether is the plainest dropout there is.
    public var staleAfter: Double

    public init(
        deadRMS: [TrackRole: Float], voiceRMS: Float,
        restartAfter: Double, restartMinOtherVoice: Double,
        restartEvery: Double, maxRestartsPerStretch: Int,
        warnAfter: Double, warnMinOtherVoice: Double, warnEvery: Double,
        gapMinSeconds: Double, gapMinOtherVoice: Double, staleAfter: Double
    ) {
        self.deadRMS = deadRMS
        self.voiceRMS = voiceRMS
        self.restartAfter = restartAfter
        self.restartMinOtherVoice = restartMinOtherVoice
        self.restartEvery = restartEvery
        self.maxRestartsPerStretch = maxRestartsPerStretch
        self.warnAfter = warnAfter
        self.warnMinOtherVoice = warnMinOtherVoice
        self.warnEvery = warnEvery
        self.gapMinSeconds = gapMinSeconds
        self.gapMinOtherVoice = gapMinOtherVoice
        self.staleAfter = staleAfter
    }

    public static let standard = DropoutPolicy(
        deadRMS: [.system: 0.0001, .mic: 0.00003],   // -80 dBFS, -90 dBFS
        voiceRMS: 0.016,                             // -36 dBFS
        restartAfter: 20, restartMinOtherVoice: 5,
        restartEvery: 60, maxRestartsPerStretch: 5,
        warnAfter: 90, warnMinOtherVoice: 20, warnEvery: 300,
        gapMinSeconds: 120, gapMinOtherVoice: 30,
        staleAfter: 5
    )
}

/// A stretch of one track that was dead while the other one talked.
/// Times are seconds on the caller's clock (the session's, for the audit).
public struct TrackGap: Equatable, Codable, Sendable {
    public let role: TrackRole
    public let start: Double
    public let end: Double
    /// Seconds of speech on the other track inside the stretch.
    public let otherVoiced: Double

    public init(role: TrackRole, start: Double, end: Double, otherVoiced: Double) {
        self.role = role
        self.start = start
        self.end = end
        self.otherVoiced = otherVoiced
    }

    public var seconds: Double { end - start }
}

public enum DropoutEvent: Equatable, Sendable {
    /// Rebuild this track's capture — the cheap first answer.
    case restart(TrackRole, deadFor: Double, attempt: Int)
    /// Tell the owner: restarting did not bring the track back.
    case warn(TrackRole, deadFor: Double, otherVoiced: Double)
    /// The track is alive again after a restart or a warning.
    case recovered(TrackRole, deadFor: Double)
}

public final class TrackDropoutDetector {
    public let policy: DropoutPolicy

    private struct Stretch {
        var lastSampleAt: Double?
        var deadSince: Double?
        var otherVoiced: Double = 0
        var restarts = 0
        var lastRestartAt: Double?
        var lastWarnAt: Double?
    }

    private var state: [TrackRole: Stretch] = [:]
    private var pending: [DropoutEvent] = []
    public private(set) var gaps: [TrackGap] = []

    /// `roles` are the tracks this session actually records; `start` is when
    /// it began, so a track that never delivers a single buffer is caught by
    /// the staleness rule like one that stopped halfway.
    public init(roles: Set<TrackRole>, policy: DropoutPolicy = .standard, start: Double) {
        self.policy = policy
        for role in roles { state[role] = Stretch(lastSampleAt: start) }
    }

    /// One buffer's worth of level. `at` is the moment the buffer *ends*,
    /// `seconds` its length.
    public func feed(_ role: TrackRole, rms: Float, seconds: Double, at t: Double) {
        guard var me = state[role] else { return }
        let begin = t - seconds
        me.lastSampleAt = t
        if rms < (policy.deadRMS[role] ?? 0) {
            if me.deadSince == nil {
                me.deadSince = begin
                me.otherVoiced = 0
                me.restarts = 0
                me.lastRestartAt = nil
                me.lastWarnAt = nil
            }
        } else if let since = me.deadSince {
            close(&me, role: role, since: since, end: begin)
        }
        state[role] = me

        // Speech on this track is evidence against the other one's silence
        // being natural.
        if rms >= policy.voiceRMS, var other = state[role.other], other.deadSince != nil {
            other.otherVoiced += seconds
            state[role.other] = other
        }
    }

    /// What should happen now. Call often; events are not repeated faster
    /// than the policy allows.
    public func evaluate(now t: Double) -> [DropoutEvent] {
        var events = pending
        pending = []
        for role in TrackRole.allCases {
            guard var me = state[role] else { continue }
            if me.deadSince == nil, let last = me.lastSampleAt, t - last > policy.staleAfter {
                me.deadSince = last
                me.otherVoiced = 0
                me.restarts = 0
                me.lastRestartAt = nil
                me.lastWarnAt = nil
            }
            guard let since = me.deadSince else { continue }
            let deadFor = t - since

            if deadFor >= policy.restartAfter,
               me.otherVoiced >= policy.restartMinOtherVoice,
               me.restarts < policy.maxRestartsPerStretch,
               me.lastRestartAt.map({ t - $0 >= policy.restartEvery }) ?? true {
                me.restarts += 1
                me.lastRestartAt = t
                events.append(.restart(role, deadFor: deadFor, attempt: me.restarts))
            }
            if deadFor >= policy.warnAfter,
               me.otherVoiced >= policy.warnMinOtherVoice,
               me.lastWarnAt.map({ t - $0 >= policy.warnEvery }) ?? true {
                me.lastWarnAt = t
                events.append(.warn(role, deadFor: deadFor, otherVoiced: me.otherVoiced))
            }
            state[role] = me
        }
        return events
    }

    /// How long `role` has been dead as of `now`, or nil while it is alive.
    public func deadFor(_ role: TrackRole, now t: Double) -> Double? {
        guard let me = state[role] else { return nil }
        if let since = me.deadSince { return t - since }
        if let last = me.lastSampleAt, t - last > policy.staleAfter { return t - last }
        return nil
    }

    /// Forget everything about the current stretches — after a pause, which
    /// removes time from both tracks on purpose and must not read as silence.
    public func reset(at t: Double) {
        for role in Array(state.keys) { state[role] = Stretch(lastSampleAt: t) }
        pending = []
    }

    /// Close any open stretch at `t` and return every gap found.
    public func finish(at t: Double) -> [TrackGap] {
        for role in TrackRole.allCases {
            guard var me = state[role], let since = me.deadSince else { continue }
            close(&me, role: role, since: since, end: t)
            state[role] = me
        }
        pending = []
        return gaps
    }

    private func close(_ me: inout Stretch, role: TrackRole, since: Double, end: Double) {
        let length = end - since
        if length >= policy.gapMinSeconds, me.otherVoiced >= policy.gapMinOtherVoice {
            gaps.append(TrackGap(role: role, start: since, end: end, otherVoiced: me.otherVoiced))
        }
        if me.restarts > 0 || me.lastWarnAt != nil {
            pending.append(.recovered(role, deadFor: length))
        }
        me.deadSince = nil
        me.otherVoiced = 0
        me.restarts = 0
        me.lastRestartAt = nil
        me.lastWarnAt = nil
    }

    /// The whole detector over two level series sampled every `step` seconds
    /// (index 0 covers [0, step)). A nil series is a track the session did not
    /// record. This is what the post-call audit runs.
    public static func scan(
        mic: [Float]?, system: [Float]?, step: Double = 1, policy: DropoutPolicy = .standard
    ) -> [TrackGap] {
        var roles = Set<TrackRole>()
        if mic != nil { roles.insert(.mic) }
        if system != nil { roles.insert(.system) }
        let detector = TrackDropoutDetector(roles: roles, policy: policy, start: 0)
        let count = max(mic?.count ?? 0, system?.count ?? 0)
        for i in 0..<count {
            let t = Double(i + 1) * step
            // A track that ended early is dead for the rest of the call.
            if let mic { detector.feed(.mic, rms: i < mic.count ? mic[i] : 0, seconds: step, at: t) }
            if let system { detector.feed(.system, rms: i < system.count ? system[i] : 0, seconds: step, at: t) }
        }
        let total = Double(count) * step
        // Silence from the very first second that ends later in the call is
        // the call not having started yet — chatting in the room before the
        // others join — not a capture that broke. A far end that is dead from
        // the first second to the last is still a hole.
        return detector.finish(at: total).filter { !($0.start <= step && $0.end < total) }
    }
}
