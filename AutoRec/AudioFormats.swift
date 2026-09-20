import AVFoundation
import Foundation

/// How the two audio tracks are written *while* a call is being recorded, and
/// how a track left behind by a crash is made whole again.
///
/// The format is uncompressed linear PCM in a CAF container, not AAC in an
/// .m4a — and that choice is the entire reason this file exists.
///
/// AAC is variable-bitrate: an .m4a (or a CAF holding AAC) is undecodable until
/// its packet/sample table is written, and that only happens when the file is
/// closed. Kill the process mid-call and every byte on disk is worthless — the
/// 1.5.2 SIGABRT lost a whole call exactly this way.
///
/// PCM has no packet table: frames are fixed size, so whatever reached the disk
/// is decodable. CAF on top of it is what makes the file *self-describing*
/// while still open — CoreAudio writes the Audio Data chunk's size as -1
/// ("extends to the end of the file") and patches in the real size only at
/// close. Measured on this machine (2026-09-20): a writer SIGKILLed after 3 s
/// leaves `data ffffffffffffffff` in the header, and both AVAudioFile and
/// ffmpeg read back all 3.0 s of it.
///
/// The cost is roughly 1 GB per hour across both tracks, and it is paid only
/// until the transcript exists — `TrackCompressor` then turns each track into
/// AAC and deletes the PCM.
///
/// подход из amanu (MIT, gsamat/amanu): Audio/AudioLevel.swift (enum AudioFormats)
enum AudioFormats {
    /// Extension of a track that is being (or was being) recorded.
    static let trackExtension = "caf"
    /// Extension of a track that has been archived after transcription.
    static let archiveExtension = "m4a"

    /// 16-bit little-endian PCM at the device's own sample rate.
    ///
    /// 16 bits because the difference from 24-bit or float is inaudible under
    /// speech and halves the bytes at risk; the native rate because resampling
    /// inside the capture callback is one more thing that can fail mid-call
    /// (1.4.0–1.4.2 shipped three separate resampling bugs).
    static func pcmSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    // MARK: - Repairing a track a crash left open

    /// Result of inspecting/repairing one CAF.
    enum RepairOutcome {
        /// The file was closed properly; nothing to do.
        case alreadyClosed
        /// The header said "-1" and has been rewritten to `frames` whole frames.
        case repaired(frames: Int64, droppedBytes: Int64)
        /// Not a CAF we understand, or too damaged to reason about. Left untouched.
        case unrecognised(String)
    }

    /// Finish the job the killed process never got to: write the real byte count
    /// into the Audio Data chunk header and drop a torn final frame.
    ///
    /// Strictly speaking this is optional — a -1 data chunk is legal CAF and
    /// readers cope. We do it anyway for two reasons: a hard kill can leave a
    /// *partial* frame at the tail (ffmpeg reports "Packet corrupt" on it), and
    /// a file with a real size in its header behaves like every other recording
    /// for anything that touches it later. It is pure arithmetic on 8 bytes of
    /// header plus a truncate, so it cannot make a readable file unreadable.
    @discardableResult
    static func repairInterruptedCAF(at url: URL) -> RepairOutcome {
        guard let handle = try? FileHandle(forUpdating: url) else {
            return .unrecognised("cannot open for writing")
        }
        defer { try? handle.close() }

        guard let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64,
              fileSize > 8 else {
            return .unrecognised("file is empty")
        }
        guard let magic = try? handle.read(upToCount: 8), magic.count == 8,
              magic.prefix(4) == Data("caff".utf8) else {
            return .unrecognised("not a CAF")
        }

        // Walk the chunk list. Every chunk carries its own size, so the only
        // one we can't skip over is the unfinished Audio Data chunk — which is
        // always last, because it is what the writer was still appending to.
        var offset: Int64 = 8
        var bytesPerFrame: Int64 = 0

        while offset + 12 <= fileSize {
            try? handle.seek(toOffset: UInt64(offset))
            guard let header = try? handle.read(upToCount: 12), header.count == 12 else { break }
            let type = header.prefix(4)
            let size = Int64(bitPattern: UInt64(bigEndian: header.subdata(in: 4..<12)
                .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }))

            if type == Data("desc".utf8) {
                // Audio Description: we need mBytesPerPacket / mFramesPerPacket
                // to know how many bytes one frame of this track occupies.
                guard let desc = try? handle.read(upToCount: 32), desc.count == 32 else {
                    return .unrecognised("truncated desc chunk")
                }
                // CAFAudioFormat layout: mSampleRate(8) mFormatID(4)
                // mFormatFlags(4) mBytesPerPacket(4) mFramesPerPacket(4)
                // mChannelsPerFrame(4) mBitsPerChannel(4).
                let bytesPerPacket = Int64(UInt32(bigEndian: desc.subdata(in: 16..<20)
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                let framesPerPacket = Int64(UInt32(bigEndian: desc.subdata(in: 20..<24)
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                // Only constant-bitrate formats have a meaningful bytes-per-frame.
                // Anything else is by definition not the PCM we write, and
                // guessing at its framing is how you corrupt a recording.
                guard framesPerPacket == 1, bytesPerPacket > 0 else {
                    return .unrecognised("not constant-bitrate PCM")
                }
                bytesPerFrame = bytesPerPacket
            }

            if type == Data("data".utf8) {
                guard size == -1 else { return .alreadyClosed }
                guard bytesPerFrame > 0 else { return .unrecognised("no usable desc chunk") }

                // The data chunk's payload starts with a 4-byte mEditCount,
                // then the audio itself.
                let payloadStart = offset + 12
                let available = fileSize - payloadStart
                guard available >= 4 else { return .unrecognised("no audio in data chunk") }
                let audioBytes = available - 4
                let wholeFrames = audioBytes / bytesPerFrame
                let keptBytes = 4 + wholeFrames * bytesPerFrame

                var beSize = UInt64(keptBytes).bigEndian
                let sizeData = withUnsafeBytes(of: &beSize) { Data($0) }
                try? handle.seek(toOffset: UInt64(offset + 4))
                try? handle.write(contentsOf: sizeData)
                // Only after the header is correct — a truncate that lands
                // first would momentarily describe more audio than exists.
                if keptBytes < available {
                    try? handle.truncate(atOffset: UInt64(payloadStart + keptBytes))
                }
                try? handle.synchronize()
                return .repaired(frames: wholeFrames, droppedBytes: available - keptBytes)
            }

            guard size >= 0 else { break }
            offset += 12 + size
        }
        return .unrecognised("no data chunk")
    }

    // MARK: - Disk space

    /// Warn (loudly, in the log) when there isn't comfortably enough room for a
    /// PCM session.
    ///
    /// The numbers: 48 kHz stereo 16-bit system audio is 192 KB/s ≈ 690 MB/h,
    /// mono mic is half that, so both tracks together run at roughly 1 GB/h,
    /// plus ~270 MB/h of screen video. 5 GB is therefore about four hours of
    /// recording — longer than any call we expect, with room left over for the
    /// OS, which starts misbehaving well before a volume is actually full.
    /// Below 1.5 GB there is under an hour left and the warning gets blunt.
    ///
    /// This only warns. Refusing to record because a disk looks tight would
    /// lose a call for certain, in exchange for maybe not losing its tail.
    static func warnIfLowDiskSpace(at directory: URL) {
        guard let free = freeBytes(at: directory) else { return }
        let gb = Double(free) / 1_073_741_824
        if free < 1_610_612_736 {
            log(String(format: "[AudioFormats] ⚠️⚠️ Свободно всего %.1f ГБ — это меньше часа записи в PCM. Освободите место.", gb))
        } else if free < 5_368_709_120 {
            log(String(format: "[AudioFormats] ⚠️ Свободно %.1f ГБ (~%.0f ч записи). Запись идёт несжатой до расшифровки.", gb, gb))
        }
    }

    /// Space actually available to us on the volume holding `directory`, in
    /// bytes. `forImportantUsage` is the honest number: it accounts for purgeable
    /// caches macOS will evict for us, which plain `volumeAvailableCapacity`
    /// does not.
    static func freeBytes(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
