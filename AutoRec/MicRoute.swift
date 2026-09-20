import CoreAudio
import Foundation

/// The input devices macOS is routing through, asked of Core Audio directly.
///
/// AVAudioEngine cannot answer any of this: it binds to whatever the default
/// input was when it started and stays there, so the only way to notice that
/// the microphone moved is to ask the hardware layer ourselves.
///
/// Read on demand, never cached — every answer here is a fact about right now,
/// and a stale one is worse than the query it saved.
///
/// подход из amanu (MIT, gsamat/amanu): Sources/amanu/Audio/AudioDevices.swift
enum AudioDevices {
    static func defaultInput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    static func name(of device: AudioObjectID?) -> String? {
        guard let device, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The name property follows Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let name = value.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }

    /// Whether the device can record at all. Worth asking because a process
    /// doing duplex I/O lists its *output* device among the devices it runs
    /// input on (anything with echo cancellation on, including us), and a
    /// speaker is not a microphone.
    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0
        else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr
        else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let channels = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
        return channels > 0
    }
}

/// Which microphone the "me" track ought to be recording right now.
///
/// The answer MemorAI used to give was "whichever one was the default when the
/// engine started", which is wrong twice over. It is wrong when the default
/// changes mid-call: `AVAudioEngine` stays on the device it was built around,
/// posts no notification and reports no error, so the file keeps the old
/// microphone to the end of the call. And it is wrong when the call app is not
/// on the default at all — pick another microphone in Zoom's settings and Zoom
/// moves while the system default, and therefore we, do not.
///
/// So the question is asked the way call detection already asks its own:
/// follow the app that is holding the microphone. `kAudioProcessPropertyDevices`
/// says which device a process is running input on, and that device — not the
/// default — is the one the person is talking into. The default is the fallback
/// for everything else: no call app, no answer from Core Audio, a meeting held
/// in an app we do not recognise.
///
/// подход из amanu (MIT, gsamat/amanu): Sources/amanu/Audio/MicRoute.swift
enum MicRoute {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String?
    }

    /// The microphone capture should be on. Nil when the system will not name
    /// one, which leaves the engine to its own default — the behaviour of every
    /// version before this one.
    static func preferred() -> Device? {
        // `AudioProcesses` already enumerates the processes holding the mic,
        // with system daemons (Siri, dictation) and our own engine filtered
        // out — exactly the set this question needs, and the same set call
        // detection and the Core Audio tap work from.
        var seen = Set<AudioObjectID>()
        let callAppInputs = AudioProcesses.micHolders()
            .flatMap { inputDevices(of: $0.object) }
            // A process doing duplex I/O lists its *output* device here too
            // (anything with echo cancellation on, including us), and a speaker
            // is not a microphone.
            .filter { AudioDevices.hasInput($0) && seen.insert($0).inserted }
            .map { Device(id: $0, name: AudioDevices.name(of: $0)) }
        let fallback = AudioDevices.defaultInput().map {
            Device(id: $0, name: AudioDevices.name(of: $0))
        }
        return choose(callAppInputs: callAppInputs, default: fallback)
    }

    /// The choice itself, over answers Core Audio has already given — the same
    /// rule without the questions.
    ///
    /// A call app on the default device is the ordinary case and settles
    /// itself. When several are open on different devices, the default wins if
    /// it is among them, because that is the one the person last chose
    /// somewhere that asked; otherwise the first, because any microphone
    /// somebody is talking into beats a default nobody selected.
    static func choose(callAppInputs: [Device], default fallback: Device?) -> Device? {
        guard !callAppInputs.isEmpty else { return fallback }
        if let fallback = fallback, callAppInputs.contains(fallback) { return fallback }
        return callAppInputs[0]
    }

    /// The devices a process is running input on — asked of the system rather
    /// than inferred from whatever happens to be the default.
    private static func inputDevices(of process: AudioObjectID) -> [AudioObjectID] {
        // Per-process device lists arrived in macOS 14.4; below that the
        // default input is all there is to go on.
        guard #available(macOS 14.4, *) else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(process, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }
}
