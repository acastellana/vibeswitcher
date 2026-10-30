import AppKit
import Combine
import SwiftUI
import VibeCore

private struct DictationEnvironmentKey: EnvironmentKey {
    static let defaultValue: DictationController? = nil
}

extension EnvironmentValues {
    /// Push to talk for the composer (none in the benches and tests: no mic button).
    var dictation: DictationController? {
        get { self[DictationEnvironmentKey.self] }
        set { self[DictationEnvironmentKey.self] = newValue }
    }
}

/// The composer's mic: hold it to record, let go to transcribe. A Claude Code session's goes through Claude's /voice;
/// any other's through OpenAI, and without a key it says one is needed, and a press says where to add it.
struct DictationButton: View {
    @ObservedObject var dictation: DictationController
    let rowID: String
    /// The session's agent: Claude's dictation for a Claude Code session the window can type into.
    var agent: Agent? = nil
    let vocabulary: () -> @Sendable () -> String
    /// The composer the press went down in (its release is that one's).
    @State private var held: String?

    var body: some View {
        let recording = dictation.isRecording(rowID)
        let transcribing = dictation.isTranscribing(rowID)
        let claude = dictation.usesClaude(rowID, agent: agent)
        let missing = !claude && dictation.keyState == .missing
        ZStack {
            if transcribing {
                ProgressView().controlSize(.small).accessibilityLabel("Transcribing")
            } else {
                Image(systemName: missing ? "mic.slash" : recording ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundStyle(recording ? Color.white : missing ? Color.secondary : Color.primary)
                    .accessibilityLabel(missing ? "Dictation needs an OpenAI API key" : recording ? "Recording: release to transcribe" : "Hold to dictate")
            }
        }
        .frame(width: 26, height: 26)
        .background(Circle().fill(recording ? Color.red.opacity(0.85) : Color.clear))
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard held == nil else { return }
                held = rowID
                dictation.press(rowID, agent: agent, vocabulary: vocabulary())
            }
            .onEnded { _ in
                dictation.release(held ?? rowID)
                held = nil
            })
        // VoiceOver's press: once to start, once to stop.
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if recording { dictation.release(rowID) } else { dictation.press(rowID, agent: agent, vocabulary: vocabulary()) }
        }
        .help(missing ? "Dictation needs an OpenAI API key: add one in Settings › General › Dictation"
              : claude ? "Hold to dictate with Claude's /voice (or hold \(dictation.shortcuts) in the box); let go and the text lands here to check before sending. Esc cancels."
              : "Hold to dictate (or hold \(dictation.shortcuts) in the box); let go and the text lands here to check before sending")
        .padding(.bottom, 6)
    }
}

/// The line under the composer: the one-time note about OpenAI, what's happening, or what went wrong.
struct DictationStatusRow: View {
    @ObservedObject var dictation: DictationController
    let rowID: String

    var body: some View {
        if dictation.privacyNoteFor == rowID {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Dictation sends your recording to OpenAI with your API key to turn it into text, along with the project's, branches' and recent files' names to help it spell them. Nothing is kept after. The text lands here for you to check; it's never sent by itself.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Got it") { dictation.acknowledgePrivacy() }.controlSize(.small)
            }
            .padding(.leading, 30)
        } else if dictation.isClaude(rowID), dictation.isRecording(rowID) {
            claude(dictation.isListening(rowID) ? "Claude is listening… let go when you're done (Esc cancels)."
                                       : "Keep holding: Claude's dictation is starting…", color: .red)
        } else if dictation.isClaude(rowID), dictation.isTranscribing(rowID) {
            claude("Waiting for Claude to write it out… (Esc cancels; sending cancels it too)", color: .secondary)
        } else if dictation.isRecording(rowID) {
            Text("Recording… let go to transcribe (2 minutes at most).").font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 30)
        } else if dictation.isTranscribing(rowID) {
            Text("Transcribing with OpenAI…").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 30)
        } else if let notice = dictation.notices[rowID] {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(notice.text).font(.system(size: 11)).foregroundStyle(notice.info ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.settings {
                    Button("Open Settings…") { dictation.openSettings() }.controlSize(.small)
                }
                if notice.privacy {
                    Button("Open Privacy Settings…") { dictation.openPrivacy() }.controlSize(.small)
                }
                if notice.turnOn {
                    Button("Turn on Claude dictation") { dictation.turnOnClaude(rowID) }.controlSize(.small)
                        .help("Types /voice hold into the session (its prompt box must be empty); your Claude settings aren't touched otherwise")
                }
                Button { dictation.dismissNotice(rowID) } label: {
                    Image(systemName: "xmark").font(.system(size: 9)).accessibilityLabel("Dismiss")
                }
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30)
        }
    }

    /// A Claude dictation under way, held or waiting for its text, with its ✕: Esc's cancel, in every phase.
    private func claude(_ text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            Button { dictation.cancel(rowID, .button) } label: {
                Image(systemName: "xmark").font(.system(size: 9)).accessibilityLabel("Cancel dictation")
            }
            .buttonStyle(.borderless)
            .help("Cancel the dictation: Claude stops recording, and its prompt box is left as it was")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 30)
    }
}

/// Where a transcript goes in the box: at the cursor (replacing a selection), with a space on a side that touches a
/// word.
enum DictationInsert {
    static func text(_ text: String, before: Character?, after: Character?) -> String {
        var out = text
        if let before, !before.isWhitespace { out = " " + out }
        if let after, !after.isWhitespace, !after.isPunctuation { out += " " }
        return out
    }

    /// Puts `text` at `textView`'s cursor, as typed (one ⌘Z takes it out).
    static func insert(_ text: String, into textView: NSTextView) {
        let string = textView.string as NSString
        let range = textView.selectedRange()
        let before = range.location > 0 ? Character(string.substring(with: string.rangeOfComposedCharacterSequence(at: range.location - 1))) : nil
        let end = range.location + range.length
        let after = end < string.length ? Character(string.substring(with: string.rangeOfComposedCharacterSequence(at: end))) : nil
        // A step of its own: one ⌘Z takes out the transcript, not the words typed before it.
        textView.breakUndoCoalescing()
        textView.insertText(Self.text(text, before: before, after: after), replacementRange: range)
        textView.breakUndoCoalescing()
    }
}

/// Watches dictation for the transcripts of one composer's box and puts each in at its cursor once, even when it
/// arrives while another session is shown (it waits for this box to be made again).
final class DictationInbox {
    private var watching: AnyCancellable?
    private weak var dictation: DictationController?

    func watch(_ dictation: DictationController?, rowID: @escaping () -> String, textView: NSTextView) {
        guard dictation !== self.dictation else { return }
        self.dictation = dictation
        watching = dictation?.$deliveries
            .receive(on: DispatchQueue.main)
            .sink { [weak dictation, weak textView] _ in
                guard let dictation, let textView else { return }
                let row = rowID()
                // Read again here: another box for this row may have taken it already.
                guard let delivery = dictation.deliveries[row] else { return }
                DictationInsert.insert(delivery.text, into: textView)
                dictation.delivered(row, serial: delivery.serial)
            }
    }
}

/// Settings › General › Dictation: the OpenAI key (kept in the Keychain only; one in your shell or Codex's file
/// offered for import, after you confirm) and the transcription model.
struct DictationSettings: View {
    @ObservedObject var dictation: DictationController
    @State private var key = ""
    @State private var confirmingImport = false

    var body: some View {
        Section {
            LabeledContent("OpenAI API key for dictation") {
                HStack {
                    SecureField("OpenAI API key for dictation", text: $key,
                                prompt: Text(dictation.keyState == .saved ? "Saved in your Keychain" : "sk-…"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit(save)
                    Button("Save", action: save).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if dictation.keyState == .saved {
                        Button("Remove") { dictation.saveKey(nil) }
                    }
                }
            }
            LabeledContent("Key in use") {
                HStack {
                    Text(Self.line(dictation.keyState)).foregroundStyle(.secondary)
                    if dictation.keyState != .saved, let found = dictation.found {
                        Button("Import from \(found.source == .shell ? "your shell" : "Codex")…") { confirmingImport = true }
                            .confirmationDialog("Import \(found.source.name) into your Keychain for dictation?",
                                                isPresented: $confirmingImport) {
                                Button("Import") { dictation.importFound() }
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("VibeSwitcher keeps a copy in your login Keychain and uses it only to send your recordings to OpenAI.")
                            }
                    }
                }
            }
            Picker("Model", selection: $dictation.model) {
                ForEach(OpenAITranscription.models, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Hold Space to dictate", isOn: $dictation.holdSpace)
                .help(Self.holdSpaceHelp)
            Text(Self.holdSpaceHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Silence the Mac while dictating", isOn: $dictation.silenceMac)
                .help(Self.silenceHelp)
            Text(Self.silenceHelp).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = dictation.keyNotice { Text(notice).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Dictation")
        } footer: {
            SettingsFooter("Hold the mic in the composer (or \(dictation.shortcuts) in its box), on the Mac or the phone, and speak: when you let go, the recording goes to OpenAI with this key and the text lands in the box for you to check before sending. It goes with the project's, its branches' and recent files' names, to spell them right; nothing else, and no recording is kept. The key stays on this Mac, in your login Keychain, and the phone's recordings are transcribed here. \(OpenAITranscription.defaultModel) is OpenAI's most accurate.")
        }
    }

    static let holdSpaceHelp = "In the composer's box, hold Space alone for a moment to dictate, as \(DictationController.shortcut) does; let go to finish. A tap types a space, and the spaces a hold typed come out. Holding Space to type many spaces doesn't work while this is on."

    static let silenceHelp = "While you hold the mic, the Mac's sound is muted so it isn't recorded; it comes back as it was when you let go."

    static func line(_ state: DictationController.KeyState) -> String {
        switch state {
        case .saved: return "Saved in your Keychain"
        case .missing: return "None: dictation is off"
        case .unknown: return "Looking…"
        }
    }

    private func save() {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        dictation.saveKey(value)
        key = ""
    }
}
