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
/// engine started", and that is wrong the moment the person changes microphone
/// mid-call: `AVAudioEngine` stays on the device it was built around, posts no
/// notification and reports no error, so the file keeps the old microphone to
/// the end of the call.
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
        guard let id = AudioDevices.defaultInput() else { return nil }
        return Device(id: id, name: AudioDevices.name(of: id))
    }
}
