import AVFoundation
import MemorAICore
import XCTest

/// The 18.11 failure: a 49-minute call was skipped as "too short" because two
/// ffmpeg probes timed out and the failure read as 0 seconds. Everything here
/// runs on synthetic numbers, buffers and temp files — no recording involved.
final class TrackLengthTests: XCTestCase {

    // MARK: - TrackLength.resolve

    func testTimedOutProbeIsUnknownNotZero() {
        // Every source fails, the way both ffmpeg probes did on 18.11.
        let length = TrackLength.resolve(fileExists: true, sources: [{ nil }, { nil }])
        XCTAssertEqual(length, .unknown)
        XCTAssertNil(length.seconds)
    }

    func testRecordedLengthAnswersBeforeAnySlowSource() {
        var probed = false
        let length = TrackLength.resolve(fileExists: true, sources: [
            { 2956.8 },
            { probed = true; return nil },
        ])
        XCTAssertEqual(length, .measured(2956.8))
        XCTAssertFalse(probed, "a later (slow) source must not run once an earlier one answered")
    }

    func testFallsThroughToTheFirstSourceThatAnswers() {
        let length = TrackLength.resolve(fileExists: true, sources: [{ nil }, { 12.5 }, { 99 }])
        XCTAssertEqual(length, .measured(12.5))
    }

    func testMissingFileIsMissing() {
        XCTAssertEqual(TrackLength.resolve(fileExists: false, sources: [{ 10 }]), .missing)
    }

    func testNonsenseValuesAreNotMeasurements() {
        XCTAssertEqual(TrackLength.resolve(fileExists: true, sources: [{ -1 }, { .nan }]), .unknown)
    }

    // MARK: - TranscriptionGate

    func testTheIncidentIsRetriedNotSkipped() {
        let gate = TranscriptionGate.decide(
            mic: .unknown, system: .unknown, minSeconds: 1, finalAttempt: false)
        XCTAssertEqual(gate, .undetermined)
    }

    func testUnknownStaysUndeterminedEvenOnTheLastAttempt() {
        let gate = TranscriptionGate.decide(
            mic: .unknown, system: .unknown, minSeconds: 1, finalAttempt: true)
        XCTAssertEqual(gate, .undetermined, "never 'too short' without a measurement")
    }

    func testOnlyMeasuredShortTracksAreTooShort() {
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .measured(0), system: .measured(0.4),
                                     minSeconds: 1, finalAttempt: false),
            .tooShort)
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .measured(0), system: .missing,
                                     minSeconds: 1, finalAttempt: false),
            .tooShort)
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .missing, system: .missing,
                                     minSeconds: 1, finalAttempt: false),
            .tooShort)
    }

    func testBothMeasuredProceedsWithBoth() {
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .measured(2956.8), system: .measured(2957.9),
                                     minSeconds: 1, finalAttempt: false),
            .proceed(mic: true, system: true))
    }

    func testOneUnknownTrackWaitsThenStopsHoldingTheOtherUp() {
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .measured(60), system: .unknown,
                                     minSeconds: 1, finalAttempt: false),
            .undetermined, "retry first: the unknown track may be the far end")
        XCTAssertEqual(
            TranscriptionGate.decide(mic: .measured(60), system: .unknown,
                                     minSeconds: 1, finalAttempt: true),
            .proceed(mic: true, system: false))
    }

    func testThereIsAtLeastOneDelayedRetry() {
        XCTAssertFalse(TranscriptionGate.retryDelays.isEmpty)
        XCTAssertTrue(TranscriptionGate.retryDelays.allSatisfy { $0 >= 30 },
                      "the first retry must outlast the video mux that slowed the probe")
    }

    // MARK: - CAFHeader

    /// A minimal CAF: header, `desc` for 16-bit PCM, optional `free`, `data`.
    private func caf(sampleRate: Double, channels: UInt32, frames: Int,
                     dataSize: Int64? = nil, tornBytes: Int = 0, freeBytes: Int = 0,
                     framesPerPacket: UInt32 = 1) -> Data {
        var d = Data("caff".utf8)
        d.append(be16(1)); d.append(be16(0))

        d.append(Data("desc".utf8)); d.append(be64(32))
        d.append(be64(sampleRate.bitPattern))
        d.append(Data("lpcm".utf8))
        d.append(be32(0xC))                       // signed int, packed
        d.append(be32(2 * channels))              // bytes per packet
        d.append(be32(framesPerPacket))
        d.append(be32(channels))
        d.append(be32(16))

        if freeBytes > 0 {
            d.append(Data("free".utf8)); d.append(be64(UInt64(freeBytes)))
            d.append(Data(count: freeBytes))
        }

        let audio = frames * Int(2 * channels) + tornBytes
        d.append(Data("data".utf8))
        d.append(be64(UInt64(bitPattern: dataSize ?? Int64(4 + audio))))
        d.append(be32(0))                         // mEditCount
        d.append(Data(count: audio))
        return d
    }

    private func be16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
    private func be64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    func testClosedMonoTrack() {
        let file = caf(sampleRate: 48_000, channels: 1, frames: 48_000 * 3, freeBytes: 4000)
        XCTAssertEqual(CAFHeader.duration(header: file, fileSize: Int64(file.count)), 3.0)
    }

    func testOpenDataChunkExtendsToEndOfFile() {
        // Size -1 is what a still-open (or killed) recording has on disk.
        let file = caf(sampleRate: 48_000, channels: 2, frames: 24_000, dataSize: -1, tornBytes: 3)
        let header = file.prefix(CAFHeader.headerBytes)
        XCTAssertEqual(CAFHeader.duration(header: header, fileSize: Int64(file.count)), 0.5,
                       "a torn final frame is not counted")
    }

    func testLongCallNeedsOnlyTheHeader() {
        // 49 minutes of mono 48 kHz — the header alone answers, no audio read.
        let frames = 2956 * 48_000
        let headerOnly = caf(sampleRate: 48_000, channels: 1, frames: 0,
                             dataSize: Int64(4 + frames * 2))
        let fileSize = Int64(headerOnly.count + frames * 2)
        XCTAssertEqual(CAFHeader.duration(header: headerOnly, fileSize: fileSize), 2956)
    }

    func testEmptyRecordingIsAMeasuredZero() {
        let file = caf(sampleRate: 48_000, channels: 1, frames: 0)
        XCTAssertEqual(CAFHeader.duration(header: file, fileSize: Int64(file.count)), 0)
    }

    func testNotACafOrNotPCMIsNil() {
        XCTAssertNil(CAFHeader.duration(header: Data("RIFF....WAVE".utf8), fileSize: 12))
        let vbr = caf(sampleRate: 48_000, channels: 1, frames: 10, framesPerPacket: 1024)
        XCTAssertNil(CAFHeader.duration(header: vbr, fileSize: Int64(vbr.count)))
        let truncated = caf(sampleRate: 48_000, channels: 1, frames: 10).prefix(30)
        XCTAssertNil(CAFHeader.duration(header: truncated, fileSize: 30))
    }

    /// Cross-check against what CoreAudio itself writes, using the app's
    /// recording settings, on a synthetic temp file.
    func testMatchesAFileWrittenByAVAudioFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorai-tracklength-\(UUID().uuidString).caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: 72_000))
            buffer.frameLength = 72_000
            try file.write(from: buffer)
        }
        let seconds = try XCTUnwrap(CAFHeader.duration(of: url))
        XCTAssertEqual(seconds, 1.5, accuracy: 0.0001)
    }

    // MARK: - ArchivePlan

    func testNoTranscriptStillGetsACompactCopyButKeepsTheOriginal() {
        XCTAssertEqual(ArchivePlan.decide(hasPCM: true, hasTranscript: false, hasGaps: false),
                       .copyKeepOriginal)
    }

    func testTranscriptArchivesAndGapsHold() {
        XCTAssertEqual(ArchivePlan.decide(hasPCM: true, hasTranscript: true, hasGaps: false), .archive)
        XCTAssertEqual(ArchivePlan.decide(hasPCM: true, hasTranscript: true, hasGaps: true), .hold)
        XCTAssertEqual(ArchivePlan.decide(hasPCM: true, hasTranscript: false, hasGaps: true), .hold)
        XCTAssertEqual(ArchivePlan.decide(hasPCM: false, hasTranscript: true, hasGaps: false), .hold)
    }
}
