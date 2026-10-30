import CoreAudio
import Foundation
import VibeCore

/// The Mac's sound outputs as the silencer sees them: CoreAudio in the app (`CoreAudioOutputs`), a fake in every test
/// (no test changes the Mac's volume or mute). Devices are CoreAudio's ids for this launch; a UID names one across
/// launches (the marker's). Main thread.
protocol AudioOutputs: AnyObject {
    /// The default output device now, if any.
    func defaultOutput() -> AudioDeviceID?
    /// The device with this UID, if it's there now.
    func device(uid: String) -> AudioDeviceID?
    func uid(_ device: AudioDeviceID) -> String?
    func name(_ device: AudioDeviceID) -> String
    /// Its master mute when it has one that can be set (nil: none, or not settable).
    func mute(_ device: AudioDeviceID) -> Bool?
    /// Whether it was set.
    @discardableResult func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool
    /// Its output volume scalars (0…1) that can be set, by element (0: the master, then each channel); empty: none.
    func volumes(_ device: AudioDeviceID) -> [UInt32: Float32]
    /// Whether it was set.
    @discardableResult func setVolume(_ device: AudioDeviceID, element: UInt32, _ value: Float32) -> Bool
}

/// Silences the Mac's sound output while a dictation records, and puts it back exactly as it was when the last one
/// ends: the default output's master mute when it has one it lets us set (a device you had muted is left alone), else
/// each of its volumes set to 0 and back to what it was. The device silenced is the one restored, even when the default
/// output changed in between; one with neither (some Bluetooth outputs) is skipped, said in app.log.
///
/// Before anything is changed a private marker (`marker`) says what and what it was; each change leaves it once it's
/// put back, so a launch that finds one (the app ended mid-dictation without quitting) puts it back from there
/// (`recover`). One that couldn't be (its device away, AirPods in their case) stays there and is tried again at each
/// launch and before each silencing, so a device is never left silent for good. Main thread.
final class OutputSilencer {
    /// What was changed on a device, and what it was before: written to the marker before the change.
    struct Change: Codable, Equatable {
        struct Volume: Codable, Equatable {
            var element: UInt32
            var value: Float32
        }

        var uid: String
        /// Its name, for app.log.
        var name: String
        /// Its master mute was turned on (it was off).
        var muted: Bool
        /// Its volumes set to 0, each with what it was (empty when muted instead).
        var volumes: [Volume]
    }

    /// The marker, in VibeSwitcher's folder.
    static var defaultMarker: URL { VibePaths.root.appendingPathComponent("dictation-silenced.json") }

    private let outputs: AudioOutputs
    private let marker: URL
    private let log: (String) -> Void
    /// What's silenced now and must be put back (nil: nothing of ours is).
    private(set) var change: Change?
    /// Silenced for someone now (a device skipped or already muted counts: nothing's done again until all let go).
    private(set) var active = false

    init(outputs: AudioOutputs, marker: URL = OutputSilencer.defaultMarker,
         log: @escaping (String) -> Void = { Breadcrumbs.shared.note($0) }) {
        self.outputs = outputs
        self.marker = marker
        self.log = log
    }

    /// Who wants the sound off now (the composers recording): silenced from the first, put back after the last.
    func set(holders: Set<String>) {
        if holders.isEmpty { restore() } else { silence() }
    }

    /// The default output silenced, unless it is already (by us, or muted by you).
    func silence() {
        guard !active else { return }
        active = true
        guard let device = outputs.defaultOutput() else {
            return log("dictation: no sound output to silence")
        }
        // What earlier runs couldn't put back first: a device back now isn't silenced again from 0.
        let earlier = pending()
        var left = putBack(earlier, why: " (left silenced earlier)")
        if left != earlier { try? save(left) }
        let name = outputs.name(device)
        guard let uid = outputs.uid(device) else {
            return log("dictation: skipped silencing \(name): it has no UID to restore it by")
        }
        var change = Change(uid: uid, name: name, muted: false, volumes: [])
        if let muted = outputs.mute(device) {
            if muted { return log("dictation: skipped silencing \(name): already muted") }
            change.muted = true
        } else {
            let volumes = outputs.volumes(device)
            guard !volumes.isEmpty else {
                return log("dictation: skipped silencing \(name): no mute or volume it lets us set")
            }
            change.volumes = volumes.keys.sorted().map { Change.Volume(element: $0, value: volumes[$0]!) }
        }
        left.removeAll { $0.uid == uid }
        do {
            try save(left + [change])
        } catch {
            // Not changed without the marker: a crash then could leave it silent with nothing to put it back.
            return log("dictation: couldn't write the marker, \(name) not silenced")
        }
        self.change = change
        if change.muted {
            outputs.setMute(device, true)
        } else {
            for volume in change.volumes { outputs.setVolume(device, element: volume.element, 0) }
        }
        log("dictation: silenced \(name) (\(change.muted ? "muted" : "volume to 0"))")
    }

    /// What was silenced put back as it was, and taken out of the marker once it is (also at quit).
    func restore() {
        active = false
        guard let change else { return }
        self.change = nil
        let others = pending().filter { $0 != change }
        try? save(others + putBack([change], why: ""))
    }

    /// At launch: what a run that ended while silenced, or a device away at its restore, left in the marker, put back.
    func recover() {
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? save(putBack(pending(), why: " (left silenced earlier)"))
    }

    /// The changes in the marker (an unreadable one is dropped, said in app.log).
    private func pending() -> [Change] {
        guard let data = try? Data(contentsOf: marker) else { return [] }
        guard let changes = try? JSONDecoder().decode([Change].self, from: data) else {
            try? FileManager.default.removeItem(at: marker)
            log("dictation: a silencing marker was left unreadable, removed")
            return []
        }
        return changes
    }

    /// The marker holding `changes`, or none when there are none.
    private func save(_ changes: [Change]) throws {
        guard !changes.isEmpty else {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            return
        }
        try VibePaths.writePrivate(try JSONEncoder().encode(changes), to: marker)
    }

    /// Each change put back; those that couldn't be (their device away, or CoreAudio refused) returned.
    private func putBack(_ changes: [Change], why: String) -> [Change] {
        changes.filter { change in
            guard let device = outputs.device(uid: change.uid) else {
                log("dictation: \(change.name) isn't connected now, restored when it's back\(why)")
                return true
            }
            var done = true
            if change.muted {
                done = outputs.setMute(device, false)
            } else {
                for volume in change.volumes where !outputs.setVolume(device, element: volume.element, volume.value) { done = false }
            }
            log(done ? "dictation: restored \(change.name)\(why)" : "dictation: couldn't restore \(change.name)\(why), tried again later")
            return !done
        }
    }
}

/// The Mac's outputs through CoreAudio (the app's; never run by the tests).
final class CoreAudioOutputs: AudioOutputs {
    func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    func device(uid: String) -> AudioDeviceID? {
        var address = Self.address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { self.uid($0) == uid }
    }

    func uid(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }

    func name(_ device: AudioDeviceID) -> String { string(device, kAudioObjectPropertyName) ?? "the sound output" }

    func mute(_ device: AudioDeviceID) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard settable(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func volumes(_ device: AudioDeviceID) -> [UInt32: Float32] {
        var volumes: [UInt32: Float32] = [:]
        for element in 0...UInt32(channels(device)) {
            var address = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
            guard settable(device, &address) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { volumes[element] = value }
        }
        return volumes
    }

    func setVolume(_ device: AudioDeviceID, element: UInt32, _ value: Float32) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: element)
        var value = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                                element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private func settable(_ device: AudioDeviceID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// Its output channels, from its streams.
    private func channels(_ device: AudioDeviceID) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector, scope: kAudioObjectPropertyScopeGlobal)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
