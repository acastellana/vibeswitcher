import CoreAudio
import Foundation
import Testing
@testable import VibeCore
@testable import VibeSwitcher

/// The Mac's sound silenced while a dictation records and put back exactly as it was: muted at the start, restored on
/// release, cancel, an error, quitting, and at the next launch from the marker a crash left; a device already muted
/// left muted; a volume-only device's volumes back to the value; overlapping recordings silence once; the device
/// silenced is the one restored. Every device here is `FakeOutputs`: no test touches the Mac's sound.
@MainActor
struct OutputSilencerTests {
    let temp = Scratch()

    /// Sound outputs as the test sets them, keeping each change made to them.
    final class FakeOutputs: AudioOutputs {
        final class Device {
            let uid: String
            let name: String
            /// nil: no master mute it lets us set.
            var mute: Bool?
            var volumes: [UInt32: Float32]
            init(uid: String, name: String, mute: Bool? = false, volumes: [UInt32: Float32] = [:]) {
                (self.uid, self.name, self.mute, self.volumes) = (uid, name, mute, volumes)
            }
        }

        var devices: [AudioDeviceID: Device] = [:]
        var defaultID: AudioDeviceID?
        /// Every set, in order: the device and what was set.
        private(set) var mutes: [(AudioDeviceID, Bool)] = []
        private(set) var volumeSets: [(AudioDeviceID, UInt32, Float32)] = []

        init(_ devices: [AudioDeviceID: Device], default id: AudioDeviceID?) {
            self.devices = devices
            defaultID = id
        }

        func defaultOutput() -> AudioDeviceID? { defaultID }
        func device(uid: String) -> AudioDeviceID? { devices.first { $0.value.uid == uid }?.key }
        func uid(_ device: AudioDeviceID) -> String? { devices[device]?.uid }
        func name(_ device: AudioDeviceID) -> String { devices[device]?.name ?? "?" }
        func mute(_ device: AudioDeviceID) -> Bool? { devices[device]?.mute }
        func setMute(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
            mutes.append((device, muted))
            guard let found = devices[device], found.mute != nil else { return false }
            found.mute = muted
            return true
        }
        func volumes(_ device: AudioDeviceID) -> [UInt32: Float32] { devices[device]?.volumes ?? [:] }
        func setVolume(_ device: AudioDeviceID, element: UInt32, _ value: Float32) -> Bool {
            volumeSets.append((device, element, value))
            guard let found = devices[device], found.volumes[element] != nil else { return false }
            found.volumes[element] = value
            return true
        }
    }

    static func speakers() -> FakeOutputs {
        FakeOutputs([1: .init(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")], default: 1)
    }

    func silencer(_ outputs: FakeOutputs, marker: URL? = nil, lines: LogLines = LogLines()) -> OutputSilencer {
        OutputSilencer(outputs: outputs, marker: marker ?? self.marker("silencer"),
                       log: { lines.all.append($0) })
    }

    /// The marker's path in a new private scratch folder (the app's is `~/.vibeswitcher`, there from launch).
    func marker(_ prefix: String) -> URL {
        let folder = temp.url(prefix)
        try? VibePaths.ensurePrivate(folder)
        return folder.appendingPathComponent("dictation-silenced.json")
    }

    final class LogLines {
        var all: [String] = []
    }

    /// A controller recording through `FakeRecorder` (OpenAI's way, answered by `FakeHTTP`), silencing with `silencer`.
    func controller(_ silencer: OutputSilencer, recorder: DictationTests.FakeRecorder = DictationTests.FakeRecorder(),
                    defaults: UserDefaults? = nil) -> DictationController {
        let defaults = defaults ?? temp.defaults("silencer")
        defaults.set(true, forKey: DictationController.privacyNotedKey)
        var transcription = OpenAITranscription(client: DictationTests.FakeHTTP())
        transcription.boundary = { "BOUNDARY" }
        return DictationController(keyStore: AppProof.MemorySecret(DictationTests.key), recorder: recorder,
                                   microphone: DictationTests.FakeMicrophone(), silencer: silencer, transcription: transcription,
                                   defaults: defaults, findKey: { nil }, background: { $0() }, schedule: DictationTests.FakeClock().schedule)
    }

    // MARK: - Through the controller

    @Test func mutedWhileRecordingAndRestoredOnRelease() async {
        let outputs = Self.speakers()
        let silencer = silencer(outputs)
        let controller = controller(silencer)
        #expect(controller.silenceMac, "on by default")
        controller.press("row") { "" }
        #expect(controller.isRecording("row"))
        #expect(outputs.devices[1]?.mute == true)
        controller.release("row")
        // Back as soon as the recording ends, before the transcript comes.
        #expect(outputs.devices[1]?.mute == false)
        #expect(await until { controller.runs.isEmpty })
        #expect(outputs.mutes.map(\.1) == [true, false])
    }

    @Test func restoredOnCancel() {
        let outputs = Self.speakers()
        let controller = controller(silencer(outputs))
        controller.press("row") { "" }
        #expect(outputs.devices[1]?.mute == true)
        controller.cancel("row")
        #expect(outputs.devices[1]?.mute == false)
        #expect(controller.runs.isEmpty)
    }

    /// Claude's run ending on an error while it records (here its settings refuse it): the sound comes back.
    @Test func restoredWhenTheRecordingEndsOnAnError() async {
        let outputs = Self.speakers()
        let controller = controller(silencer(outputs))
        controller.claudeSession = { _ in ClaudeVoiceSession(keys: { _ in true }, screen: { $0(nil) }, command: { _ in true }) }
        controller.claudeSettings = { _ in ClaudeVoiceSettings(mode: "tap") }
        controller.press("row", agent: .claude) { "" }
        #expect(controller.isRecording("row") && outputs.devices[1]?.mute == true)
        #expect(await until { controller.runs.isEmpty })
        #expect(controller.notices["row"] != nil)
        #expect(outputs.devices[1]?.mute == false)
    }

    @Test func restoredAtQuitAndTheMarkerRemoved() {
        let outputs = Self.speakers()
        let marker = self.marker("quit")
        let silencer = silencer(outputs, marker: marker)
        let controller = controller(silencer)
        controller.press("row") { "" }
        #expect(outputs.devices[1]?.mute == true)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        // applicationWillTerminate's call, with the recording still under way.
        silencer.restore()
        #expect(outputs.devices[1]?.mute == false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A press in another composer ends the recording under way and starts its own: the sound stays off in between,
    /// silenced once and restored after the last.
    @Test func overlappingRecordingsSilenceOnceAndRestoreAfterTheLast() async {
        let outputs = Self.speakers()
        let controller = controller(silencer(outputs))
        controller.press("a") { "" }
        controller.press("b") { "" }
        #expect(controller.isRecording("b") && !controller.isRecording("a"))
        #expect(outputs.mutes.map(\.1) == [true])
        controller.release("b")
        #expect(outputs.mutes.map(\.1) == [true, false])
        #expect(await until { controller.runs.isEmpty })

        // The silencer itself: holders come and go, the device is set once each way.
        let direct = Self.speakers()
        let silencer = silencer(direct)
        silencer.set(holders: ["a"])
        silencer.set(holders: ["a", "b"])
        silencer.set(holders: ["b"])
        #expect(direct.mutes.map(\.1) == [true])
        silencer.set(holders: [])
        #expect(direct.mutes.map(\.1) == [true, false])
    }

    @Test func offInSettingsNothingIsSilencedAndTurningItOffRestores() {
        let outputs = Self.speakers()
        let defaults = temp.defaults("silencer-off")
        let controller = controller(silencer(outputs), defaults: defaults)
        controller.press("row") { "" }
        #expect(outputs.devices[1]?.mute == true)
        controller.silenceMac = false
        #expect(outputs.devices[1]?.mute == false)
        #expect(defaults.object(forKey: DictationController.silenceKey) as? Bool == false)
        controller.cancel("row")

        let again = Self.speakers()
        let off = self.controller(silencer(again), defaults: defaults)
        #expect(!off.silenceMac)
        off.press("row") { "" }
        #expect(off.isRecording("row"))
        #expect(again.mutes.isEmpty && again.volumeSets.isEmpty)
        off.cancel("row")
    }

    // MARK: - The silencer

    @Test func anAlreadyMutedDeviceStaysMuted() {
        let outputs = FakeOutputs([1: .init(uid: "u", name: "Studio Display", mute: true)], default: 1)
        let lines = LogLines()
        let silencer = silencer(outputs, lines: lines)
        silencer.set(holders: ["row"])
        silencer.set(holders: [])
        #expect(outputs.devices[1]?.mute == true)
        #expect(outputs.mutes.isEmpty)
        #expect(lines.all == ["dictation: skipped silencing Studio Display: already muted"])
    }

    @Test func aVolumeOnlyDeviceGetsEachVolumeBackExactly() {
        let before: [UInt32: Float32] = [0: 0.6123457, 1: 0.3, 2: 0.87654321]
        let outputs = FakeOutputs([7: .init(uid: "usb", name: "USB Audio", mute: nil, volumes: before)], default: 7)
        let silencer = silencer(outputs)
        silencer.silence()
        #expect(outputs.devices[7]?.volumes == [0: 0, 1: 0, 2: 0])
        silencer.restore()
        #expect(outputs.devices[7]?.volumes == before)
        #expect(outputs.mutes.isEmpty)
    }

    @Test func aSwitchOfOutputMidRecordingRestoresTheDeviceSilenced() {
        let outputs = FakeOutputs([1: .init(uid: "speakers", name: "Speakers"), 2: .init(uid: "headphones", name: "Headphones")], default: 1)
        let silencer = silencer(outputs)
        silencer.set(holders: ["row"])
        outputs.defaultID = 2
        silencer.set(holders: [])
        #expect(outputs.devices[1]?.mute == false)
        #expect(outputs.devices[2]?.mute == false)
        #expect(outputs.mutes.allSatisfy { $0.0 == 1 })
    }

    @Test func anOutputWithNoMuteOrVolumeIsSkippedWithALine() {
        let outputs = FakeOutputs([3: .init(uid: "airpods", name: "AirPods Pro", mute: nil)], default: 3)
        let marker = self.marker("skip")
        let lines = LogLines()
        let silencer = silencer(outputs, marker: marker, lines: lines)
        silencer.set(holders: ["row"])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        silencer.set(holders: [])
        #expect(outputs.mutes.isEmpty && outputs.volumeSets.isEmpty)
        #expect(lines.all == ["dictation: skipped silencing AirPods Pro: no mute or volume it lets us set"])
    }

    /// app.log says what was silenced and restored by the device's name, never its UID.
    @Test func theLinesNameTheDeviceOnly() {
        let outputs = Self.speakers()
        let lines = LogLines()
        let silencer = silencer(outputs, lines: lines)
        silencer.set(holders: ["row"])
        silencer.set(holders: [])
        #expect(lines.all == ["dictation: silenced MacBook Pro Speakers (muted)", "dictation: restored MacBook Pro Speakers"])
        #expect(!lines.all.joined().contains("BuiltInSpeakerDevice"))
        #expect(lines.all.allSatisfy { AppHealth.errorKind($0) == nil })
    }

    // MARK: - The marker

    /// The marker is written, private, before the device changes; a launch that finds it (the app ended mid-dictation
    /// without quitting) puts the device back and removes it.
    @Test func aLeftoverMarkerAtLaunchRestoresTheDeviceAndGoes() throws {
        let before: [UInt32: Float32] = [0: 0.42, 1: 0.7071068]
        let outputs = FakeOutputs([4: .init(uid: "usb", name: "USB Audio", mute: nil, volumes: before)], default: 4)
        let marker = self.marker("crash")
        let lines = LogLines()
        silencer(outputs, marker: marker).silence()
        #expect(outputs.devices[4]?.volumes == [0: 0, 1: 0])
        let mode = try FileManager.default.attributesOfItem(atPath: marker.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // The next launch: a new silencer, nothing in memory.
        let next = silencer(outputs, marker: marker, lines: lines)
        next.recover()
        #expect(outputs.devices[4]?.volumes == before)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(lines.all == ["dictation: restored USB Audio (left silenced by the last run)"])
        // Nothing left: a second launch does nothing.
        next.recover()
        #expect(lines.all.count == 1)

        // A muted one, too.
        let speakers = Self.speakers()
        silencer(speakers, marker: marker).silence()
        #expect(speakers.devices[1]?.mute == true)
        silencer(speakers, marker: marker).recover()
        #expect(speakers.devices[1]?.mute == false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
