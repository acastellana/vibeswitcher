import Foundation
import VibeCore

/// The words a dictation is likely to hold that a transcriber wouldn't guess: the project's name, its branches and
/// the files the session worked on lately. Sent as OpenAI's `prompt`, nothing else of the session.
enum DictationVocabulary {
    /// The prompt's length at most (OpenAI rejects a prompt over the model's limit; whisper's is 224 tokens).
    static let maxCharacters = 600
    static let maxFiles = 24
    static let maxBranches = 8
    /// How much of a transcript's end is read for its files.
    static let transcriptTail = 256 * 1024

    /// "Words that may come up: VibeSwitcher, main, agent/x, ComposerView.swift." Names once each, in order (the
    /// project, then branches, then files), credentials masked, cut at a name's end to `maxCharacters`.
    static func prompt(project: String?, branches: [String], files: [String]) -> String {
        var seen = Set<String>()
        var names: [String] = []
        for name in [project].compactMap({ $0 }) + branches.prefix(maxBranches) + files.prefix(maxFiles) {
            let clean = Redaction.secrets(in: name.filter { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, !clean.contains("•"), seen.insert(clean).inserted else { continue }
            names.append(clean)
        }
        guard !names.isEmpty else { return "" }
        let lead = "Words that may come up: "
        var text = lead
        for name in names {
            let piece = (text == lead ? "" : ", ") + name
            if text.count + piece.count + 1 > maxCharacters { break }
            text += piece
        }
        return text == lead ? "" : text + "."
    }

    /// The file names the conversation read, edited or wrote, the latest first.
    static func files(in entries: [ChatEntry]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for entry in entries.reversed() {
            guard case .tool(let tool) = entry.kind else { continue }
            let path: String
            switch tool.detail {
            case .edit(let p, _), .write(let p, _), .read(let p): path = p
            default: continue
            }
            let name = (path as NSString).lastPathComponent
            if !name.isEmpty, seen.insert(name).inserted { names.append(name) }
            if names.count >= maxFiles { break }
        }
        return names
    }

    /// The file names in the end of the transcript at `path` (checked to be an agent's, under `home`).
    static func files(transcript path: String?, home: String = NSHomeDirectory()) -> [String] {
        guard let path, let (url, format) = TranscriptReader.checkedURL(path, home: home),
              let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(transcriptTail) ? size - UInt64(transcriptTail) : 0
        guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.readToEnd() else { return [] }
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data.subdata(in: data.index(after: newline)..<data.endIndex) }
        let entries = ChatReader.read(data, format: format).events.compactMap { event -> ChatEntry? in
            if case .entry(let entry) = event { return entry }
            return nil
        }
        return files(in: entries)
    }

    /// The checked-out branch, then the other local branches by their last commit, the latest first.
    static func branches(in folder: String?) -> [String] {
        guard let folder, FileManager.default.fileExists(atPath: folder) else { return [] }
        var names = GitBranch.current(in: folder).map { [$0] } ?? []
        guard !names.isEmpty else { return [] }
        let listed = Git.run(["for-each-ref", "--sort=-committerdate", "--count=\(maxBranches)", "--format=%(refname:short)", "refs/heads"],
                             in: folder, timeout: 5)
        if listed.ok {
            for line in listed.output.split(separator: "\n") {
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return Array(names.prefix(maxBranches))
    }

    /// A session's prompt: its project, its folder's branches, its transcript's files. Runs git: never on main.
    static func prompt(for session: Session, home: String = NSHomeDirectory()) -> String {
        prompt(project: session.project, branches: branches(in: session.cwd), files: files(transcript: session.transcriptPath, home: home))
    }
}
