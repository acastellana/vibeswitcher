import Foundation
import Testing
import VibeCore
import VibeHost
@testable import VibeSwitcher

/// Where the briefing's ElevenLabs key comes from (`BriefingKey`): the Keychain item, else the login shell's
/// ELEVENLABS_API_KEY, else ~/.config/elevenlabs/key.env. Every source is a stand-in (a memory store, a closure, a
/// string): never the user's shell, Keychain or home. The keys are made up.
@MainActor
struct BriefingKeyTests {
    typealias Stub = BriefingButtonTests.Stub
    static let saved = "sk" + "_" + String(repeating: "5aved", count: 6)
    static let fromShell = "sk" + "_" + String(repeating: "5he11", count: 6)
    static let fromFile = "sk" + "_" + String(repeating: "f11e", count: 8)
    static let fileText = "ELEVENLABS_API_KEY=\(fromFile)\n"

    /// Counts the shell's reads.
    final class FakeShell: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: String?
        init(_ value: String?) { self.value = value }
        var reads: Int { lock.withLock { count } }
        func read() -> String? { lock.withLock { count += 1; return value } }
    }

    func key(saved: String? = nil, shell: String? = nil, file: String? = nil) -> (BriefingKey, AppProof.MemorySecret, FakeShell) {
        let store = AppProof.MemorySecret(saved)
        let fake = FakeShell(shell)
        return (BriefingKey(saved: store, shell: { fake.read() }, file: { file }), store, fake)
    }

    // MARK: - The order

    @Test func eachSourceAlone() {
        #expect(key(saved: Self.saved).0.resolve() == (Self.saved, .keychain))
        #expect(key(shell: Self.fromShell).0.resolve() == (Self.fromShell, .shell(variable: "ELEVENLABS_API_KEY")))
        #expect(key(file: Self.fileText).0.resolve() == (Self.fromFile, .file(path: "~/.config/elevenlabs/key.env")))
        #expect(key().0.resolve() == (nil, .absent))
        #expect(key(saved: Self.saved).0.read() == Self.saved)
        #expect(key(shell: Self.fromShell).0.read() == Self.fromShell)
        #expect(key(file: Self.fileText).0.read() == Self.fromFile)
    }

    @Test func theKeychainThenTheShellThenTheFile() {
        let (all, _, shell) = key(saved: Self.saved, shell: Self.fromShell, file: Self.fileText)
        #expect(all.resolve() == (Self.saved, .keychain))
        // With a saved key, no shell is started.
        #expect(shell.reads == 0)
        #expect(key(shell: Self.fromShell, file: Self.fileText).0.resolve() == (Self.fromShell, .shell(variable: "ELEVENLABS_API_KEY")))
        // A shell value that isn't a key (a space, an expansion left in) falls through to the file.
        #expect(key(shell: "sk_a b", file: Self.fileText).0.resolve().source == .file(path: "~/.config/elevenlabs/key.env"))
        #expect(key(shell: "", file: nil).0.resolve().source == .absent)
    }

    /// One shell per launch: read the first time it's needed, kept, and read again only when Settings opens.
    @Test func theShellIsReadOnceUntilRefreshed() {
        let (key, _, shell) = key(shell: Self.fromShell)
        for _ in 0..<5 { #expect(key.read() == Self.fromShell) }
        #expect(shell.reads == 1)
        shell.value = nil
        #expect(key.read() == Self.fromShell)
        key.refresh()
        #expect(key.read() == nil)
        #expect(shell.reads == 2)
        // A shell without it is remembered too.
        #expect(key.read() == nil)
        #expect(shell.reads == 2)
    }

    /// Saving and removing touch the Keychain item only.
    @Test func removeClearsOnlyTheSavedOne() {
        let (key, store, _) = key(shell: Self.fromShell, file: Self.fileText)
        #expect(key.write(Self.saved))
        #expect(store.read() == Self.saved)
        #expect(key.resolve() == (Self.saved, .keychain))
        #expect(key.write(nil))
        #expect(store.read() == nil)
        #expect(key.resolve() == (Self.fromShell, .shell(variable: "ELEVENLABS_API_KEY")))
    }

    // MARK: - The key file

    @Test func theFilesLines() {
        let name = "ELEVENLABS_API_KEY"
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY=sk_plain", name: name) == "sk_plain")
        #expect(BriefingKey.parse("export ELEVENLABS_API_KEY=sk_exported\n", name: name) == "sk_exported")
        #expect(BriefingKey.parse("export   ELEVENLABS_API_KEY=\"sk_double\"", name: name) == "sk_double")
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY='sk_single'  # mine", name: name) == "sk_single")
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY=sk_bare # a comment", name: name) == "sk_bare")
        #expect(BriefingKey.parse("  ELEVENLABS_API_KEY=sk_indented  ", name: name) == "sk_indented")
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY=sk_crlf\r\nOTHER=x\r\n", name: name) == "sk_crlf")
        #expect(BriefingKey.parse("# ElevenLabs\r\n\r\n# ELEVENLABS_API_KEY=sk_commented\r\nELEVENLABS_API_KEY=sk_after\r\n", name: name) == "sk_after")
        // The last good line wins, as in the shell; other names and look-alikes are left alone.
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY=sk_first\nELEVENLABS_API_KEY=sk_second", name: name) == "sk_second")
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY_OLD=sk_old\nMY_ELEVENLABS_API_KEY=sk_mine", name: name) == nil)
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY =sk_spaced", name: name) == nil)
    }

    /// Nothing is run or expanded: a line that would need the shell, or doesn't parse, counts as none.
    @Test func aMalformedFileIsIgnored() {
        let name = "ELEVENLABS_API_KEY"
        for text in ["ELEVENLABS_API_KEY=\"sk_unclosed", "ELEVENLABS_API_KEY='sk_unclosed\n",
                     "ELEVENLABS_API_KEY=$(security find-generic-password -w)", "ELEVENLABS_API_KEY=`cat key`",
                     "ELEVENLABS_API_KEY=${OTHER}", "ELEVENLABS_API_KEY=\"sk_a\"trailing", "ELEVENLABS_API_KEY=",
                     "ELEVENLABS_API_KEY=\"\"", "ELEVENLABS_API_KEY", "just some words", "",
                     String(decoding: (0..<512).map { UInt8($0 % 256) }, as: UTF8.self)] {
            #expect(BriefingKey.parse(text, name: name) == nil, "\(text.prefix(60))")
        }
        // A bad line after a good one leaves the good one.
        #expect(BriefingKey.parse("ELEVENLABS_API_KEY=sk_good\nELEVENLABS_API_KEY=\"sk_bad", name: name) == "sk_good")
        #expect(key(file: "ELEVENLABS_API_KEY=\"sk_unclosed").0.resolve() == (nil, .absent))
    }

    /// The real file reader: a missing file, one too big for a key file, one that isn't UTF-8.
    @Test func readingTheFile() throws {
        let scratch = Scratch()
        let folder = scratch.url("key-file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("key.env").path
        #expect(BriefingKey.readFile(path) == nil)
        try Self.fileText.write(toFile: path, atomically: true, encoding: .utf8)
        #expect(BriefingKey.readFile(path) == Self.fileText)
        try Data(repeating: 0x41, count: BriefingKey.fileLimit + 1).write(to: URL(fileURLWithPath: path))
        #expect(BriefingKey.readFile(path) == nil)
        try Data([0xff, 0xfe, 0x00, 0x41]).write(to: URL(fileURLWithPath: path))
        #expect(BriefingKey.readFile(path) == nil)
    }

    /// The reader asks the login shell the way the host starts a session (`HostedSession.arguments`), so .zshrc is read.
    @Test func theShellIsAskedAsASessionIs() {
        let argv = LoginShellVariable.arguments(shell: "/bin/zsh", name: "ELEVENLABS_API_KEY")
        #expect(Array(argv.prefix(5)) == HostedSession.arguments(shell: "/bin/zsh", command: argv[4], keepShell: false))
    }

    // MARK: - Settings and the briefing

    let voiceID = "key-voice-\(UUID().uuidString.prefix(8))"
    let suite = "briefing-key-tests-\(UUID().uuidString)"

    func model(_ key: BriefingKey, voice: BriefingButtonTests.FakeVoice, defaults: UserDefaults) -> BriefingModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return BriefingModel(snapshot: { .init(boards: [:], sessions: []) }, language: { .english }, keyStore: key,
                             generate: { _ in "Quiet day." }, client: ElevenLabs(voice: voiceID, session: URLSession(configuration: configuration)),
                             voice: voice, defaults: defaults)
    }

    /// Everything Settings › Briefing says about the key (`BriefingSettings.KeyText`, all the view is given), and
    /// everything the model publishes for it.
    func settingsText(_ model: BriefingModel) -> String {
        let text = BriefingSettings.KeyText(model.keySource)
        return [text.prompt, text.line, text.offersSave ? "Save to Keychain" : "", String(describing: model.keySource),
                model.keyNotice ?? "", model.voiceNotice ?? ""].joined(separator: "\n")
    }

    @Test func eachStatesText() {
        typealias KeyText = BriefingSettings.KeyText
        #expect(KeyText(.keychain) == KeyText(prompt: "Saved in your Keychain", line: "Saved in your Keychain", offersSave: false))
        #expect(KeyText(.shell(variable: "ELEVENLABS_API_KEY"))
            == KeyText(prompt: "Paste one to use instead", line: "From your shell: ELEVENLABS_API_KEY", offersSave: true))
        #expect(KeyText(.file(path: "~/.config/elevenlabs/key.env"))
            == KeyText(prompt: "Paste one to use instead", line: "From ~/.config/elevenlabs/key.env", offersSave: true))
        #expect(KeyText(.absent) == KeyText(prompt: "Not set", line: "None: the Mac's voice reads it", offersSave: false))
        #expect(KeyText(nil).line == "Looking…")
    }

    /// Settings names the shell's variable, offers Save to Keychain, and never shows the value; Test voice reads with
    /// the shell's key; Save to Keychain saves it, Remove takes it out again and the shell's is back.
    @Test func aShellKeyInSettingsAndTestVoice() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let (key, store, _) = key(shell: Self.fromShell)
        let voice = BriefingButtonTests.FakeVoice()
        let model = model(key, voice: voice, defaults: defaults)
        model.checkKey()
        #expect(await until { model.keySource != nil })
        #expect(model.keySource == .shell(variable: "ELEVENLABS_API_KEY"))
        #expect(model.keySaved == false)
        let shown = settingsText(model)
        #expect(shown.contains("From your shell: ELEVENLABS_API_KEY"))
        #expect(shown.contains("Save to Keychain"))
        #expect(!shown.contains(Self.fromShell))
        #expect(!shown.contains(Data(Self.fromShell.utf8).base64EncodedString()))

        Stub.expect(voice: voiceID)
        model.testVoice()
        #expect(await until { voice.played.count == 1 })
        #expect(Stub.requests(voiceID).first?.request.value(forHTTPHeaderField: "xi-api-key") == Self.fromShell)
        #expect(voice.said.isEmpty)

        model.saveFoundKey()
        #expect(await until { model.keySource == .keychain })
        #expect(store.read() == Self.fromShell)
        #expect(!settingsText(model).contains("Save to Keychain"))
        model.saveKey(nil)
        #expect(await until { model.keySource == .shell(variable: "ELEVENLABS_API_KEY") })
        #expect(store.read() == nil)
        // Nothing of it in the defaults.
        #expect(!defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined().contains(Self.fromShell))
    }

    /// Each state's line, with the file's name and never its key.
    @Test func settingsNamesTheFileAndNothingWhenThereIsNone() async {
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = model(key(file: Self.fileText).0, voice: .init(), defaults: defaults)
        file.checkKey()
        #expect(await until { file.keySource != nil })
        let shownFile = settingsText(file)
        #expect(shownFile.contains("From ~/.config/elevenlabs/key.env"))
        #expect(shownFile.contains("Save to Keychain"))
        #expect(!shownFile.contains(Self.fromFile))

        let none = model(key().0, voice: .init(), defaults: defaults)
        none.checkKey()
        #expect(await until { none.keySource != nil })
        let shownNone = settingsText(none)
        #expect(shownNone.contains("None: the Mac's voice reads it"))
        #expect(!shownNone.contains("Save to Keychain"))
    }
}
