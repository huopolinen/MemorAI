import AVFoundation
import Foundation

/// Puts "Я" and "Собеседник" back onto a transcript that was made from the mix.
///
/// подход из amanu (MIT, gsamat/amanu): Transcription/SpeakerAttribution.swift
///
/// The engine only ever sees one mono file, so it cannot say who spoke. But the
/// two source tracks are still on disk and they answer it directly: whoever was
/// loud on `_mic.caf` while a phrase was spoken is the person who spoke it.
///
/// The trap — and amanu paid for this one in production — is deciding that
/// phrase by phrase. The far end comes out of the speakers and straight back
/// into the room microphone, so some minority of the other person's phrases
/// really are louder on the mic track. Decide each phrase on its own and one
/// person comes out as two speakers, alternating mid-sentence. amanu's answer
/// was a majority vote per diarized voice; none of our engines diarize (whisper
/// and Groq return timings, not voices), so the same protection has to come
/// from somewhere else:
///
///  1. The leak is measured for this call, once, and subtracted. When the far
///     end is clearly speaking, whatever the mic hears at that moment *is* the
///     leak; the median of that ratio over the whole call is a constant, and a
///     constant learned call-wide cannot flip back and forth phrase by phrase.
///     Energy subtraction, not amplitude: the two signals are uncorrelated, so
///     what the microphone adds of its own is √(mic² − (leak·system)²).
///  2. When an engine *does* diarize, the per-voice majority vote from amanu
///     runs too and wins — a voice is a person, and a person keeps one side
///     from the first word to the last.
///
/// Levels are not comparable raw: the mic runs at whatever gain the device
/// picked and the system tap at playback level. Each track is therefore
/// normalized against its own loud-speech level (p90) before anything is
/// compared, and an absolute floor below that keeps a track of pure room tone
/// from being normalized up into looking like speech.
final class SpeakerAttribution {
    /// Envelope resolution. Speech energy at 100 ms is stable enough to
    /// attribute and cheap enough to compute for a two-hour call in one pass.
    static let bucket: TimeInterval = 0.1

    /// Absolute RMS floor, about −46 dBFS: below this a bucket is room tone, a
    /// fan or a hot preamp, not somebody talking.
    ///
    /// Normalizing each track against its own p90 is what makes two different
    /// gains comparable — and it is also why this floor must exist. A track
    /// carrying no speech at all still gets normalized against its own noise,
    /// so that noise comes out at the same relative level as the other track's
    /// speech and wins the comparison outright. After normalization the two
    /// cases look identical; only an absolute threshold separates them.
    static let speechFloor: Float = 0.005

    /// Below this normalized level, nothing worth attributing is on the track.
    private static let quiet: Double = 0.05

    private let micEnvelope: Envelope?
    private let systemEnvelope: Envelope?

    /// Reads both tracks once. Nil when neither could be read at all — there is
    /// nothing to say about a session whose audio we cannot open.
    ///
    /// Pass `nil` for a track that is missing or too short to count; the
    /// envelopes are reused for the silence trim as well as the attribution, so
    /// this decode happens once per session.
    init?(mic: URL?, system: URL?) {
        micEnvelope = mic.flatMap { Envelope(url: $0) }
        systemEnvelope = system.flatMap { Envelope(url: $0) }
        guard micEnvelope != nil || systemEnvelope != nil else { return nil }
    }

    /// Attribution needs two tracks. One track cannot be compared against
    /// anything: a mic-only recording may be a voice memo (all "Я") or a call
    /// on speakerphone whose far end is in the room (half "Собеседник"), and
    /// nothing in the audio distinguishes them. We label neither rather than
    /// label half of it wrong.
    var hasBothTracks: Bool { micEnvelope != nil && systemEnvelope != nil }

    /// First and last moment anybody speaks, across both tracks.
    ///
    /// This replaces ffmpeg's `silenceremove` at the head and tail of the mix,
    /// and it does so for a reason beyond taste: `silenceremove` deletes an
    /// unknown amount of audio, and after it the transcript's clock no longer
    /// has a known relationship to the tracks — which is the one thing
    /// attribution cannot do without. Trimming to bounds we computed ourselves
    /// keeps the offset exact (it is `start`), and the purpose is unchanged:
    /// Whisper never sees the pre-connect ringing or the post-goodbye dead air
    /// it likes to hallucinate subtitle credits onto.
    ///
    /// Nil when neither track ever rises above the noise floor — that session
    /// has no speech in it at all.
    func speechBounds() -> (start: TimeInterval, end: TimeInterval)? {
        let bounds = [micEnvelope, systemEnvelope].compactMap { $0?.speechBounds() }
        guard !bounds.isEmpty else { return nil }
        let start = bounds.map(\.start).min()!
        let end = bounds.map(\.end).max()!
        guard end > start else { return nil }
        // Half a second of run-up on each side: speech starts quietly, and a
        // bucket-accurate cut clips the first consonant.
        return (max(0, start - 0.5), end + 0.5)
    }

    struct Attribution {
        var segments: [AttributedSegment]
        /// Diarization label → "A"/"B"… within its side. Empty for a side that
        /// holds only one voice, because "Собеседник" beats "Собеседник A".
        var suffixes: [String: String]
        var micOffset: TimeInterval
        var systemOffset: TimeInterval
        /// How much of the far end the microphone picked up, 0…0.8.
        var leak: Double
    }

    /// Give every segment a side.
    ///
    /// `offset` is where the transcript's clock sits inside the tracks: the mix
    /// was cut at `offset` seconds, so a segment at transcript time T is at
    /// T + offset in both .caf files. It is then *verified* against the mix
    /// itself (see `alignment`), so a wrong assumption costs accuracy at the
    /// edges rather than the whole attribution.
    ///
    /// Returns nil when there is nothing to compare — one track, or two tracks
    /// on which no segment reads as speech.
    func attribute(
        segments: [TranscriptSegment],
        offset: TimeInterval,
        reference: URL?
    ) -> Attribution? {
        guard !segments.isEmpty, let mic = micEnvelope, let system = systemEnvelope else { return nil }

        // Where each track really sits under the transcript's clock.
        let mixEnvelope = reference.flatMap { Envelope(url: $0) }
        let micOffset = alignment(of: mic, to: mixEnvelope, assuming: offset, name: "mic")
        let systemOffset = alignment(of: system, to: mixEnvelope, assuming: offset, name: "system")

        let leak = leakRatio(mic: mic, system: system, skew: micOffset - systemOffset)

        // ── Pass 1: what each track says about each segment ─────────────────
        struct Reading {
            var side: SpeakerSide?
            var confidence: Double
        }
        var readings: [Reading] = segments.map { segment in
            guard segment.end > segment.start else { return Reading(side: nil, confidence: 0) }
            // Ignore the first and last fraction of a second of each segment:
            // segment boundaries from the engine are approximate, and the two
            // tracks may be a bucket or two apart. Trimming the edges can only
            // remove a neighbour's words, never add them.
            let inset = min(0.2, (segment.end - segment.start) * 0.2)
            let from = segment.start + inset
            let to = segment.end - inset
            let heard = mic.level(from: from + micOffset, to: to + micOffset)
            let theirs = system.level(from: from + systemOffset, to: to + systemOffset)
            // Subtract the far end's leak from the mic in energy terms: the two
            // are uncorrelated, so what is left is what the room itself added.
            let own = (max(0, heard * heard - (leak * theirs) * (leak * theirs))).squareRoot()

            guard own >= Self.quiet || theirs >= Self.quiet else {
                // Both tracks are silent under these words. That is a dropout
                // (or an engine hallucination), not a third speaker.
                return Reading(side: nil, confidence: 0)
            }
            let loudest = max(own, theirs)
            return Reading(
                side: own > theirs ? .me : .them,
                confidence: loudest > 0 ? abs(own - theirs) / loudest : 0
            )
        }
        guard readings.contains(where: { $0.side != nil }) else {
            log("[SpeakerAttribution] обе дорожки молчат под всеми сегментами — метки не ставлю")
            return nil
        }

        // ── Pass 2: a voice belongs to one side for the whole call ──────────
        // Only reachable when the engine diarizes. Nobody changes tracks
        // halfway through a meeting; minority readings are the room mic
        // hearing the far end through the speakers.
        var tally: [String: (me: Int, them: Int)] = [:]
        for (segment, reading) in zip(segments, readings) {
            guard let label = segment.speaker, let side = reading.side else { continue }
            var counts = tally[label] ?? (0, 0)
            if side == .me { counts.me += 1 } else { counts.them += 1 }
            tally[label] = counts
        }
        let settled = tally.mapValues { $0.me > $0.them ? SpeakerSide.me : SpeakerSide.them }
        for i in segments.indices {
            if let label = segments[i].speaker, let side = settled[label] {
                readings[i].side = side
            }
        }

        // ── Pass 3: segments nobody could decide keep the room's last side ──
        var lastDecided: SpeakerSide?
        for i in readings.indices where readings[i].side != nil { lastDecided = readings[i].side; break }
        for i in readings.indices {
            if let side = readings[i].side {
                lastDecided = side
            } else {
                readings[i].side = lastDecided
            }
        }

        // There used to be a fourth pass here that flipped a lone low-confidence
        // segment to whatever both its neighbours said, on the theory that one
        // phrase on the wrong side between two confident ones is a misreading.
        // Measured on the synthetic calls, it only ever made things worse
        // (7/10 against 8/10 on the hardest one) and never once helped, because
        // the lone segments in a real conversation are backchannels — "угу",
        // "да", "понял" — dropped into the middle of the other person's turn.
        // They are genuinely lone, genuinely short, and genuinely mine. What
        // keeps one person from splitting in two is the call-wide leak constant
        // above, not a local smoother.

        // ── Names ───────────────────────────────────────────────────────────
        var labelsPerSide: [SpeakerSide: Set<String>] = [:]
        for (segment, reading) in zip(segments, readings) {
            guard let label = segment.speaker, let side = reading.side else { continue }
            labelsPerSide[side, default: []].insert(label)
        }
        var suffixes: [String: String] = [:]
        for (_, labels) in labelsPerSide where labels.count > 1 {
            // Sorted so the letters are stable across reruns rather than
            // whatever order the set happens to iterate in.
            for (index, label) in labels.sorted().enumerated() {
                suffixes[label] = index < 26
                    ? String(UnicodeScalar(UInt8(65 + index)))
                    : String(index + 1)
            }
        }

        let attributed = zip(segments, readings).map { segment, reading in
            AttributedSegment(
                start: segment.start, end: segment.end, text: segment.text,
                side: reading.side ?? .them, label: segment.speaker,
                confidence: reading.confidence
            )
        }
        let mine = attributed.filter { $0.side == .me }.count
        log(String(
            format: "[SpeakerAttribution] %d сегментов: я %d, собеседник %d; утечка в микрофон %.2f, сдвиг дорожек mic %+.1f c / system %+.1f c",
            attributed.count, mine, attributed.count - mine, leak,
            micOffset - offset, systemOffset - offset))
        return Attribution(segments: attributed, suffixes: suffixes,
                           micOffset: micOffset, systemOffset: systemOffset, leak: leak)
    }

    // MARK: - Calibration

    /// How much of the far end the microphone picks up, as a fraction of the
    /// system track's level.
    ///
    /// Measured where the far end is clearly speaking: at those moments the mic
    /// is hearing them through the speakers plus, occasionally, me talking over
    /// them. The median throws the second case out, which is exactly why it is
    /// a median and not a mean.
    ///
    /// Capped at 0.8: a ratio near 1 means the mic track is *nothing but* leak
    /// (I never spoke, so its own p90 normalized the leak up to full scale).
    /// Subtracting all of it would then credit the entire call to the far end —
    /// true in that case, but a bad thing to get wrong, and the floor in
    /// `level` already handles a genuinely silent mic.
    private func leakRatio(mic: Envelope, system: Envelope, skew: TimeInterval) -> Double {
        let shift = Int((skew / Self.bucket).rounded())
        var ratios: [Double] = []
        for index in system.indices {
            let theirs = system.normalized(at: index)
            guard theirs >= 0.5 else { continue }
            let heard = mic.normalized(at: index + shift)
            ratios.append(heard / theirs)
        }
        // Under ~2 seconds of clear far-end speech there is nothing to measure,
        // and a median of five buckets is noise. Assume no leak.
        guard ratios.count >= 20 else { return 0 }
        ratios.sort()
        return min(0.8, max(0, ratios[ratios.count / 2]))
    }

    /// Where a track actually sits under the transcript's clock.
    ///
    /// The assumption is that the mix was cut at a known offset and both tracks
    /// run on the same clock from there. Both halves of that can be wrong: the
    /// recorders do not start on the same millisecond, and a microphone that
    /// restarts mid-call shifts everything after it. The mix is the arbiter —
    /// it literally contains both tracks — so each track's envelope is slid
    /// against the mix's and the best fit wins, within a second either way.
    ///
    /// A weak or barely-better peak is not trusted: correlating a track against
    /// a mix that is mostly the *other* person gives a flat curve, and a flat
    /// curve's argmax is noise.
    private func alignment(
        of track: Envelope, to mix: Envelope?, assuming offset: TimeInterval, name: String
    ) -> TimeInterval {
        guard let mix else { return offset }
        let base = Int((offset / Self.bucket).rounded())
        let search = Int((1.0 / Self.bucket).rounded())
        let baseline = mix.correlation(with: track, shift: base)
        var best = baseline
        var bestShift = 0
        for delta in -search...search where delta != 0 {
            let score = mix.correlation(with: track, shift: base + delta)
            if score > best { best = score; bestShift = delta }
        }
        guard bestShift != 0, best > 0.25, best > baseline + 0.02 else { return offset }
        let corrected = offset + Double(bestShift) * Self.bucket
        log(String(format: "[SpeakerAttribution] дорожка %@ сдвинута на %+.1f c относительно микса (соответствие %.2f против %.2f) — учитываю",
                   name, Double(bestShift) * Self.bucket, best, baseline))
        return max(0, corrected)
    }

    // MARK: - Envelope

    /// A track's loudness over time in fixed buckets, normalized so it can be
    /// compared against a track recorded at a different gain.
    struct Envelope {
        private let buckets: [Float]
        private let reference: Float

        var indices: Range<Int> { buckets.indices }
        var duration: TimeInterval { Double(buckets.count) * SpeakerAttribution.bucket }

        /// Read the file once, streaming, and reduce it to per-bucket RMS.
        /// Nil if the file is missing, unreadable, empty or entirely silent.
        init?(url: URL) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let file = try? AVAudioFile(forReading: url),
                  file.length > 0
            else { return nil }

            let format = file.processingFormat
            let framesPerBucket = max(1, Int(format.sampleRate * SpeakerAttribution.bucket))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(framesPerBucket * 10)
            ) else { return nil }

            var out: [Float] = []
            var carrySquares: Float = 0
            var carryFrames = 0
            let channelCount = Int(format.channelCount)

            while true {
                buffer.frameLength = 0
                guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 else { break }
                guard let channels = buffer.floatChannelData else { break }
                let frames = Int(buffer.frameLength)
                for frame in 0..<frames {
                    var mixed: Float = 0
                    for channel in 0..<channelCount { mixed += channels[channel][frame] }
                    let sample = mixed / Float(channelCount)
                    carrySquares += sample * sample
                    carryFrames += 1
                    if carryFrames == framesPerBucket {
                        out.append((carrySquares / Float(framesPerBucket)).squareRoot())
                        carrySquares = 0
                        carryFrames = 0
                    }
                }
            }
            if carryFrames > 0 {
                out.append((carrySquares / Float(carryFrames)).squareRoot())
            }
            guard !out.isEmpty else { return nil }

            // Normalized against the track's own loud speech, not its peak: one
            // door slam must not rescale a whole call.
            let sorted = out.sorted()
            let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
            guard p90 > 0 else { return nil }

            buckets = out
            reference = p90
        }

        /// This bucket's level relative to the track's own loud speech. Room
        /// tone and anything outside the file read as 0.
        func normalized(at index: Int) -> Double {
            guard index >= 0, index < buckets.count,
                  buckets[index] >= SpeakerAttribution.speechFloor else { return 0 }
            return Double(buckets[index]) / Double(reference)
        }

        /// Mean normalized loudness over a time range, in seconds. A range
        /// outside the track (it started later, or ended earlier) reads as
        /// silence, which is right: nothing of this speaker is there.
        func level(from start: TimeInterval, to end: TimeInterval) -> Double {
            let first = max(0, Int(start / SpeakerAttribution.bucket))
            let last = min(buckets.count - 1, Int(end / SpeakerAttribution.bucket))
            guard first <= last, first < buckets.count else { return 0 }
            var sum: Double = 0
            for i in first...last { sum += normalized(at: i) }
            return sum / Double(last - first + 1)
        }

        /// First and last moment this track carries speech.
        ///
        /// Three buckets in a row, not one: a key press or a chair creak clears
        /// the floor for a tenth of a second and would otherwise anchor the
        /// trim minutes before anybody said anything.
        func speechBounds() -> (start: TimeInterval, end: TimeInterval)? {
            let run = 3
            var first: Int?
            var last: Int?
            var streak = 0
            for i in buckets.indices {
                if buckets[i] >= SpeakerAttribution.speechFloor {
                    streak += 1
                    if streak >= run {
                        if first == nil { first = i - run + 1 }
                        last = i
                    }
                } else {
                    streak = 0
                }
            }
            guard let first, let last else { return nil }
            return (Double(first) * SpeakerAttribution.bucket,
                    Double(last + 1) * SpeakerAttribution.bucket)
        }

        /// Pearson correlation between this envelope and `other` slid by
        /// `shift` buckets. Scale-invariant, so two tracks at different gains
        /// still line up; nil overlap or a constant stretch scores 0.
        func correlation(with other: Envelope, shift: Int) -> Double {
            let from = max(0, -shift)
            let to = min(buckets.count, other.buckets.count - shift)
            // Under five seconds of overlap there is not enough to fit.
            guard to - from >= 50 else { return 0 }

            var sumA = 0.0, sumB = 0.0
            for i in from..<to {
                sumA += Double(buckets[i])
                sumB += Double(other.buckets[i + shift])
            }
            let n = Double(to - from)
            let meanA = sumA / n, meanB = sumB / n
            var cov = 0.0, varA = 0.0, varB = 0.0
            for i in from..<to {
                let a = Double(buckets[i]) - meanA
                let b = Double(other.buckets[i + shift]) - meanB
                cov += a * b
                varA += a * a
                varB += b * b
            }
            guard varA > 0, varB > 0 else { return 0 }
            return cov / (varA * varB).squareRoot()
        }
    }
}
