import AVFoundation
import Foundation

/// Did the tracks come out as long as the call actually was?
///
/// This exists because of the most expensive bug this app has had. A track is
/// written into a file whose header was fixed by the *first* device of the
/// session; when the microphone moves mid-call to one with another sample rate
/// — AirPods switching to their 24 kHz voice mode is the usual way — every
/// buffer after that has to be converted into the file's format on the way in.
/// While that conversion was missing (up to and including 1.5.2), 24 kHz
/// samples went into a 48 kHz file and the owner's half of the call came out at
/// double speed: unintelligible to every engine, and unnoticeable from the
/// outside. The file existed, its size was plausible, and the log said nothing.
/// 114 of 370 calls in the archive are like that.
///
/// `MicRecorder.matchedToFile` is what stops it happening now. This is the
/// second line: whatever the cause, a track that is drastically shorter than
/// the call it belongs to is a damaged recording and has to say so out loud.
///
/// The arithmetic is deliberately the crudest possible — frames divided by the
/// header's sample rate against the session's own wall clock — because that is
/// exactly the comparison the broken files fail and healthy ones pass.
enum TrackSkew {
    /// Under this share of the session, a track is not "a little short", it is
    /// missing a large part of the call.
    ///
    /// Measured over the 405 archived calls that have both tracks and run
    /// longer than 30 s: 252 healthy ones sit between 0.95 and 1.05 of the far
    /// end's length, 151 damaged ones below 0.70, and exactly one call (a 31 s
    /// one, at 0.78) anywhere in between. Nothing at all lands in 0.85–0.95, so
    /// the line goes there: far enough below the healthy cluster to survive a
    /// slow device warm-up or a second of tail, far enough above the damaged
    /// one to catch even a switch that happened in the last third of a call.
    static let alarmShare = 0.85

    /// Sessions shorter than this are not judged. A fixed second or two of
    /// device warm-up is a rounding error in an hour and a third of a
    /// twenty-second voice memo, and a twenty-second memo is not worth an
    /// alarm either way.
    static let minSessionSeconds = 30.0

    /// Compare each track against the session and return the fields to merge
    /// into `meta.json`. Loud in the log when something is off; silent
    /// otherwise beyond the plain numbers, which are recorded every time so a
    /// later question ("was this one fine?") has an answer that does not
    /// require re-reading the audio.
    ///
    /// `sessionSeconds` is wall-clock time between the session marker's
    /// `started` and now, minus whatever a pause removed — pause drops real
    /// time from both tracks on purpose, and counting it would accuse every
    /// paused call of being damaged.
    static func audit(
        tag: String,
        sessionSeconds: Double,
        tracks: [String: URL]
    ) -> [String: Any] {
        var durations: [String: Double] = [:]
        for (role, url) in tracks {
            guard let seconds = duration(of: url) else { continue }
            durations[role] = round(seconds * 100) / 100
        }

        var fields: [String: Any] = ["session_seconds": round(sessionSeconds * 100) / 100]
        if !durations.isEmpty { fields["track_seconds"] = durations }
        guard sessionSeconds >= minSessionSeconds else { return fields }

        var skewed: [String: Double] = [:]
        for (role, seconds) in durations where seconds / sessionSeconds < alarmShare {
            skewed[role] = round(seconds / sessionSeconds * 1000) / 1000
        }
        guard !skewed.isEmpty else { return fields }

        fields["track_skew"] = skewed
        for (role, share) in skewed.sorted(by: { $0.key < $1.key }) {
            let seconds = durations[role] ?? 0
            log(String(
                format: "[TrackSkew] ⚠️⚠️ %@: дорожка «%@» — %.0f с при звонке в %.0f с (%.0f%%). "
                    + "Скорее всего она записана ускоренной: посреди звонка сменилось устройство ввода. "
                    + "Разобрать и починить: memorai repair-speed",
                tag, role, seconds, sessionSeconds, share * 100))
        }
        return fields
    }

    /// How long a track really is: frames divided by the sample rate its own
    /// header declares. That is the number every player and every transcription
    /// engine sees, which is the point — a file that *claims* to be half the
    /// call is half the call as far as anything downstream is concerned.
    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.fileFormat.sampleRate
        guard rate > 0, file.length > 0 else { return nil }
        return Double(file.length) / rate
    }
}
