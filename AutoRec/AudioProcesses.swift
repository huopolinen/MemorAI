import AppKit
import CoreAudio
import Darwin
import Foundation

/// The system's per-process audio objects (macOS 14.4+) — the one place that
/// asks CoreAudio "who is playing and who is listening right now".
///
/// `CallDetector` asks the first half of that question — who holds the
/// microphone, i.e. is there a call — and the Core Audio tap asks the second:
/// whose *output* should end up on the system track. Both answers come from
/// the same property list, and the tap's scope is seeded from the mic holders
/// precisely so the two can never disagree about which app the call is in.
///
/// `MicRoute` asks a third question of the same list — which *device* the call
/// app is listening to — so this is the only enumeration of audio processes in
/// the app; `CallDetector` used to carry its own copy and now calls
/// `micHolders()`.
///
/// подход из amanu (MIT, gsamat/amanu): Sources/amanu/Audio/AudioProcesses.swift
enum AudioProcesses {
    struct Process {
        /// The CoreAudio object — what a tap description wants.
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        /// Display name, falling back to the executable's own name for
        /// processes AppKit knows nothing about.
        let name: String
        let runningInput: Bool
        let runningOutput: Bool

        var label: String { name.isEmpty ? "pid \(pid)" : "\(name) (pid \(pid))" }
    }

    /// Every audio process except our own. Our own is excluded everywhere:
    /// tapping ourselves is a feedback loop, and our own AVAudioEngine holding
    /// the mic would mask the end of a call.
    static func all() -> [Process] {
        let ownPID = getpid()
        return objectList().compactMap { object -> Process? in
            guard let raw = uint32(object, kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(bitPattern: raw)
            guard pid > 0, pid != ownPID else { return nil }

            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = string(object, kAudioProcessPropertyBundleID)
                ?? app?.bundleIdentifier
                ?? ""
            let name = app?.localizedName
                ?? executableName(pid: pid)
                ?? bundleID.split(separator: ".").last.map(String.init)
                ?? ""
            return Process(
                object: object,
                pid: pid,
                bundleID: bundleID,
                name: name,
                runningInput: (uint32(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                runningOutput: (uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }

    /// Other processes currently capturing the microphone — the signal
    /// `CallDetector` turns into "a call is happening", and the seed the tap
    /// uses to work out *which app* the call belongs to.
    static func micHolders() -> [Process] {
        all().filter { $0.runningInput && isUserFacing(pid: $0.pid) }
    }

    /// Our own audio process object, so a global tap can exclude it — the
    /// CoreAudio equivalent of SCStream's `excludesCurrentProcessAudio`.
    /// Returns nil when we have never touched audio (no object exists yet),
    /// which is harmless: a tap with nothing to exclude still records.
    static func ownObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    // MARK: - Families

    /// Every process belonging to one of these families.
    ///
    /// A family is a bundle-id *prefix*, not an exact id, because the process
    /// that plays a call's audio is rarely the one you would name: Chrome
    /// renders it in `com.google.Chrome.helper.Renderer`, Teams and Zoom each
    /// ship several helpers, and matching the family catches all of them —
    /// including the ones that are not making any noise yet. A process with no
    /// bundle id at all (a command-line tool) is matched by its executable
    /// name instead, exactly.
    static func matching(families: [String]) -> [Process] {
        matching(families: families, in: all())
    }

    /// The same rule over a given list — without asking the system, so it can
    /// be reasoned about and tested.
    static func matching(families: [String], in processes: [Process]) -> [Process] {
        guard !families.isEmpty else { return [] }
        return processes.filter { belongs($0, to: families) }
    }

    static func belongs(_ process: Process, to families: [String]) -> Bool {
        process.bundleID.isEmpty
            ? families.contains(process.name)
            : families.contains { !$0.isEmpty && process.bundleID.hasPrefix($0) }
    }

    /// The family a process belongs to: the app's own id rather than its
    /// helper's, so "tap Chrome" does not mean "tap one renderer".
    static func family(of process: Process) -> String? {
        guard !process.bundleID.isEmpty else {
            return process.name.isEmpty ? nil : process.name
        }
        if let range = process.bundleID.range(of: ".helper", options: [.caseInsensitive]) {
            return String(process.bundleID[..<range.lowerBound])
        }
        return process.bundleID
    }

    // MARK: - Process identity

    /// False for system daemons (corespeechd, assistantd, coreaudiod…) that
    /// hold the mic for background OS features like Siri / dictation and must
    /// never be treated as call activity. Anything shipping from /System or
    /// /usr/… qualifies.
    static func isUserFacing(pid: pid_t) -> Bool {
        guard let path = executablePath(pid: pid) else { return false }
        if path.hasPrefix("/System/") { return false }
        if path.hasPrefix("/usr/libexec/") { return false }
        if path.hasPrefix("/usr/sbin/") { return false }
        if path.hasPrefix("/usr/bin/") { return false }
        return true
    }

    static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN, plenty for any real path
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let bytes = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard bytes > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - CoreAudio plumbing

    private static func objectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func uint32(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // These properties follow Core Foundation's create rule — the string
        // comes back retained and is ours to release, which is what
        // takeRetainedValue does.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let value
        else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func executableName(pid: pid_t) -> String? {
        guard let path = executablePath(pid: pid) else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
