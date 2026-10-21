import Foundation

/// A language the briefing is written and spoken in: its code as ElevenLabs takes it (`language_code`) and its name
/// in English, which the prompt names.
public struct BriefingLanguage: Equatable, Hashable, Sendable, Identifiable {
    public let code: String
    public let name: String
    public var id: String { code }

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }

    /// The languages ElevenLabs' current multilingual model (`eleven_v4`) speaks, by name: ISO 639-1 codes, and 639-3
    /// for the four that have none (Asturian, Cantonese, Cebuano, Filipino). From elevenlabs.io/docs/overview/models.
    public static let all: [BriefingLanguage] = [
        ("af", "Afrikaans"), ("ar", "Arabic"), ("hy", "Armenian"), ("as", "Assamese"), ("ast", "Asturian"),
        ("az", "Azerbaijani"), ("be", "Belarusian"), ("bn", "Bengali"), ("bs", "Bosnian"), ("bg", "Bulgarian"),
        ("my", "Burmese"), ("yue", "Cantonese"), ("ca", "Catalan"), ("ceb", "Cebuano"), ("zh", "Chinese (Mandarin)"),
        ("hr", "Croatian"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"), ("et", "Estonian"),
        ("fil", "Filipino"), ("fi", "Finnish"), ("fr", "French"), ("gl", "Galician"), ("ka", "Georgian"), ("de", "German"),
        ("el", "Greek"), ("gu", "Gujarati"), ("ha", "Hausa"), ("he", "Hebrew"), ("hi", "Hindi"), ("hu", "Hungarian"),
        ("is", "Icelandic"), ("id", "Indonesian"), ("ga", "Irish"), ("it", "Italian"), ("ja", "Japanese"), ("jv", "Javanese"),
        ("kn", "Kannada"), ("kk", "Kazakh"), ("ko", "Korean"), ("ky", "Kyrgyz"), ("lv", "Latvian"), ("ln", "Lingala"),
        ("lt", "Lithuanian"), ("lb", "Luxembourgish"), ("mk", "Macedonian"), ("ms", "Malay"), ("ml", "Malayalam"),
        ("mt", "Maltese"), ("mi", "Māori"), ("mr", "Marathi"), ("mn", "Mongolian"), ("ne", "Nepali"), ("no", "Norwegian"),
        ("oc", "Occitan"), ("or", "Odia"), ("ps", "Pashto"), ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"),
        ("pa", "Punjabi"), ("ro", "Romanian"), ("ru", "Russian"), ("sr", "Serbian"), ("sd", "Sindhi"), ("sk", "Slovak"),
        ("sl", "Slovenian"), ("so", "Somali"), ("es", "Spanish"), ("sw", "Swahili"), ("sv", "Swedish"), ("tg", "Tajik"),
        ("ta", "Tamil"), ("te", "Telugu"), ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("ur", "Urdu"),
        ("uz", "Uzbek"), ("vi", "Vietnamese"), ("cy", "Welsh"), ("yo", "Yoruba"),
    ].map { BriefingLanguage(code: $0.0, name: $0.1) }

    public static let english = BriefingLanguage(code: "en", name: "English")

    public static func named(_ code: String) -> BriefingLanguage? { all.first { $0.code == code } }

    /// The Mac's first preferred language ("es-ES", "zh-Hans-CN", "nb"), when the model speaks it; else English.
    public static func preferred(_ languages: [String] = Locale.preferredLanguages) -> BriefingLanguage {
        guard let first = languages.first else { return english }
        let code = String(first.lowercased().split(separator: "-").first ?? "")
        // Norwegian Bokmål and Nynorsk are Norwegian to the model; Tagalog is Filipino.
        let aliases = ["nb": "no", "nn": "no", "tl": "fil"]
        return named(aliases[code] ?? code) ?? english
    }
}

/// What a briefing is written from: for each project a lead runs, what its progress log says happened since the
/// last briefing (newest first, in plain words, redacted), its board's counts and its open questions; and the
/// sessions waiting on the user. Bounded: a briefing is thirty seconds, so its input is a page, not a day's log.
public struct BriefingInput: Equatable, Sendable {
    public struct Project: Equatable, Sendable {
        public var name: String
        /// What happened since `since`, newest first (at most `Briefing.entriesPerProject`).
        public var news: [String]
        /// How many entries there were in all, shown or not.
        public var newsCount: Int
        public var landed: Int
        public var running: Int
        public var review: Int
        public var blocked: Int
        /// The open questions for the user, most important first (at most `Briefing.questionsPerProject`).
        public var questions: [String]
        public var questionCount: Int

        public var isQuiet: Bool { news.isEmpty }
    }

    /// A session waiting on the user: its name and project.
    public struct Waiting: Equatable, Sendable {
        public var name: String
        public var project: String
    }

    /// From when it covers, and when it was composed.
    public var since: Double
    public var now: Double
    public var projects: [Project]
    public var waiting: [Waiting]
    public var waitingCount: Int
    /// The one project a project briefing is about (`Briefing.compose(project:…)`); nil: every led project.
    public var project: String? = nil

    public var isEmpty: Bool { projects.isEmpty && waiting.isEmpty }

    /// The lines the model reads: a project with nothing new is one line; one with news is a line, its entries, and
    /// its open questions. A project briefing names its questions even when it's quiet: they're what it's for.
    public var lines: [String] {
        var lines: [String] = []
        for project in projects {
            let counts = Briefing.counts(project)
            if project.isQuiet {
                lines.append("\(project.name): nothing new" + (counts.isEmpty ? "." : "; \(counts)."))
                if self.project != nil { lines += project.questions.map { "  - Question for the user: \($0)" } }
                continue
            }
            lines.append("\(project.name): \(project.newsCount) new in its log" + (counts.isEmpty ? "." : "; \(counts)."))
            lines += project.news.map { "  - \($0)" }
            if project.newsCount > project.news.count { lines.append("  - (and \(project.newsCount - project.news.count) older)") }
            lines += project.questions.map { "  - Question for the user: \($0)" }
        }
        if !waiting.isEmpty {
            let names = waiting.map { $0.name == $0.project ? $0.name : "\($0.name) (\($0.project))" }
            let more = waitingCount > waiting.count ? " and \(waitingCount - waiting.count) more" : ""
            lines.append("Sessions waiting on the user: \(names.joined(separator: ", "))\(more).")
        }
        return lines
    }

    public var text: String { Summarizer.clip(lines.joined(separator: "\n"), Briefing.inputLimit) }
}

/// One briefing as written: its text, who wrote it, and what the panel says about it.
public struct BriefingText: Equatable, Sendable {
    public var text: String
    public var language: BriefingLanguage
    /// Written by Claude; false: the English template (`Briefing.template`).
    public var byModel: Bool
    public var at: Double
    /// One line for the panel when it isn't what was asked for (the template, in English).
    public var notice: String?
}

/// The spoken briefing of what happened lately across the projects VibeSwitcher leads: composed here from what's on
/// disk (pure: the app hands it the logs, boards and sessions), written by headless Claude in the chosen language,
/// or by `template` in English when Claude isn't there.
public enum Briefing {
    /// It covers at least this long (seconds): the last briefing or this, whichever reaches further back.
    public static let window: Double = 3 * 3600
    public static let entriesPerProject = 8
    public static let questionsPerProject = 3
    public static let waitingShown = 6
    /// The longest an entry, a question or a session's name is, and the whole input.
    public static let entryLimit = 200
    public static let inputLimit = 6_000

    /// What a project gives the composer: its name, its progress log's text (nil: none yet) and its board.
    public struct Source: Sendable {
        public var name: String
        public var progress: String?
        public var board: LeadBoard

        public init(name: String, progress: String?, board: LeadBoard) {
            self.name = name
            self.progress = progress
            self.board = board
        }
    }

    /// From when a briefing at `now` covers: the last briefing, or `window` ago when that's further back.
    public static func since(lastBriefed: Double?, now: Double) -> Double {
        min(lastBriefed ?? now, now - window)
    }

    /// The input for a briefing at `now`: each project's log entries since `since(lastBriefed:now:)`, newest first,
    /// the newest `entriesPerProject` of them in plain words; its board's counts and open questions; and the sessions
    /// that need the user. Everything is redacted here, before any model sees it.
    public static func compose(_ sources: [Source], sessions: [Session], lastBriefed: Double?, now: Double) -> BriefingInput {
        let since = since(lastBriefed: lastBriefed, now: now)
        let projects = sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { source in
            let board = source.board
            let titles = Dictionary(board.tasks.map { ($0.slug, $0.title) }, uniquingKeysWith: { first, _ in first })
            let fresh = entries(source.progress ?? "").filter { $0.at >= since && $0.at <= now + 60 }.reversed().map { plain($0.text, titles: titles) }
            let questions = board.openQuestions
            func count(_ status: LeadTask.Status) -> Int { board.tasks.filter { $0.status == status }.count }
            return BriefingInput.Project(
                name: clean(source.name), news: Array(fresh.prefix(entriesPerProject)), newsCount: fresh.count,
                landed: fresh.filter { $0.hasPrefix("Landed: ") }.count,
                running: count(.running), review: count(.review), blocked: count(.blocked),
                questions: questions.prefix(questionsPerProject).map { clean($0.text) }, questionCount: questions.count)
        }
        let waiting = sessions.filter { $0.status == .needsInput && !$0.isPaused }.sorted { $0.statusSince < $1.statusSince }
        return BriefingInput(since: since, now: now, projects: projects,
                             waiting: waiting.prefix(waitingShown).map { .init(name: clean($0.displayName), project: clean($0.project)) },
                             waitingCount: waiting.count)
    }

    /// The input for a briefing of one project at `now`: `source` alone, as `compose` takes it, since that project's
    /// own last briefing (`lastBriefed`, kept apart from the global one's), and only the sessions of that project
    /// that wait on the user.
    public static func compose(project source: Source, sessions: [Session], lastBriefed: Double?, now: Double) -> BriefingInput {
        var input = compose([source], sessions: sessions.filter { $0.project == source.name }, lastBriefed: lastBriefed, now: now)
        input.project = input.projects.first?.name
        return input
    }

    /// A progress log's entries, oldest first, with their times ("- 2026-10-19 11:05 …", local time); entries
    /// without one are left out.
    static func entries(_ log: String) -> [(at: Double, text: String)] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return LeadRecords.entries(log, kind: .progress).entries.compactMap { entry in
            let line = entry.dropFirst(2).split(whereSeparator: \.isNewline).joined(separator: " ")
            guard line.count > 17, let at = formatter.date(from: String(line.prefix(16))) else { return nil }
            return (at.timeIntervalSince1970, String(line.dropFirst(17)).trimmingCharacters(in: .whitespaces))
        }
    }

    /// An entry in plain words: the tool server's lines about a task say what the task is, not its slug; commit
    /// hashes go; redacted, at most `entryLimit` characters.
    static func plain(_ text: String, titles: [String: String]) -> String {
        func title(_ slug: Substring) -> String { titles[String(slug)] ?? slug.replacingOccurrences(of: "-", with: " ") }
        var line = text
        if let match = line.wholeMatch(of: #/Merged (\S+): (.+)/#) {
            line = "Landed: \(match.2)"
        } else if let match = line.wholeMatch(of: #/Started a worker on (\S+)/#) {
            line = "Work started: \(title(match.1))"
        } else if let match = line.wholeMatch(of: #/Planned (\S+): (.+)/#) {
            line = "Planned: \(match.2)"
        } else if let match = line.wholeMatch(of: #/Audit of (\S+): (\w+), (\w+)(.*)/#) {
            line = "Checked \(title(match.1)): \(match.2 == "complete" && match.3 == "clean" ? "passed" : "didn't pass yet")"
        } else if let match = line.wholeMatch(of: #/Kept (\S+) unmerged: (.+)/#) {
            line = "Held back: \(title(match.1)) (\(match.2))"
        }
        line = line.replacing(#/\b[0-9a-f]{7,40}\b/#, with: "").replacing(#/ {2,}/#, with: " ")
        return clean(line)
    }

    /// Redacted, on one line, at most `entryLimit` characters.
    static func clean(_ text: String) -> String {
        let line = Redaction.secrets(in: text).split(whereSeparator: \.isNewline).joined(separator: " ")
        return Summarizer.clip(line.trimmingCharacters(in: .whitespaces), entryLimit)
    }

    /// "3 landed, 2 running, 1 being checked, 1 blocked, 1 question for you", leaving out the zeros.
    static func counts(_ project: BriefingInput.Project) -> String {
        var parts: [String] = []
        if project.landed > 0 { parts.append("\(project.landed) landed") }
        if project.running > 0 { parts.append("\(project.running) running") }
        if project.review > 0 { parts.append("\(project.review) being checked") }
        if project.blocked > 0 { parts.append("\(project.blocked) blocked") }
        if project.questionCount > 0 { parts.append("\(project.questionCount) question\(project.questionCount == 1 ? "" : "s") for the user") }
        return parts.joined(separator: ", ")
    }

    // MARK: Writing it

    /// The briefing for `input` in `language`: Claude's (through `generate`, blocking: call it off the main thread),
    /// or the English template, with a notice, when Claude gives nothing.
    public static func write(_ input: BriefingInput, language: BriefingLanguage, generate: (String) -> String?,
                             now: Double = Date().timeIntervalSince1970) -> BriefingText {
        if let answer = generate(BriefingPrompts.prompt(input, language: language)).flatMap(cleanAnswer) {
            return BriefingText(text: answer, language: language, byModel: true, at: now, notice: nil)
        }
        return BriefingText(text: template(input), language: .english, byModel: false, at: now,
                            notice: "Claude isn't available, so this is a template briefing in English.")
    }

    /// The most words a briefing shows: the prompt asks for 70–90; a longer answer is cut.
    public static let wordLimit = 120

    /// The model's answer as one spoken paragraph: no markdown, no quotes around it, at most `wordLimit` words.
    public static func cleanAnswer(_ text: String) -> String? {
        let words = text.replacingOccurrences(of: "**", with: "").replacing(#/(?m)^\s*(#+|[-*•])\s+/#, with: "")
            .split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        var paragraph = words.prefix(wordLimit).joined(separator: " ")
        paragraph = paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'`"))
        if words.count > wordLimit { paragraph += "…" }
        return paragraph.isEmpty ? nil : paragraph
    }

    /// The briefing without a model, in English, from the same input: a sentence per project, then who waits.
    public static func template(_ input: BriefingInput) -> String {
        if input.project != nil { return projectTemplate(input) }
        guard !input.isEmpty else { return "No project lead is running and no session needs you." }
        var sentences: [String] = []
        let quiet = input.projects.filter { $0.isQuiet && counts($0).isEmpty }
        for project in input.projects where !quiet.contains(project) {
            var parts: [String] = []
            if !project.isQuiet { parts.append("\(project.newsCount) update\(project.newsCount == 1 ? "" : "s")") }
            let counted = counts(project)
            if !counted.isEmpty { parts.append(counted) }
            var sentence = "In \(project.name), \(parts.joined(separator: "; "))."
            if let latest = project.news.first { sentence += " Latest: \(Summarizer.clip(latest, 120))." }
            sentences.append(sentence)
        }
        if !quiet.isEmpty {
            let names = quiet.map(\.name)
            sentences.append("Nothing new in \(names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!).")
        }
        if input.waitingCount > 0 {
            let names = input.waiting.map(\.name).joined(separator: ", ")
            sentences.append("\(input.waitingCount) session\(input.waitingCount == 1 ? " needs" : "s need") you: \(names).")
        }
        return sentences.joined(separator: " ").replacingOccurrences(of: "..", with: ".")
    }

    /// A project briefing without a model, in English: what's new and counted, the latest entry, the questions for
    /// the user, and who waits.
    static func projectTemplate(_ input: BriefingInput) -> String {
        guard let project = input.projects.first else { return "No project lead is running there." }
        var sentences: [String] = []
        let counted = counts(project)
        if project.isQuiet {
            sentences.append("Nothing new in \(project.name)" + (counted.isEmpty ? "." : "; \(counted)."))
        } else {
            sentences.append("In \(project.name), \(project.newsCount) update\(project.newsCount == 1 ? "" : "s")" + (counted.isEmpty ? "." : "; \(counted)."))
            if let latest = project.news.first { sentences.append("Latest: \(Summarizer.clip(latest, 120)).") }
        }
        if !project.questions.isEmpty {
            sentences.append("For you: \(project.questions.map { Summarizer.clip($0, 120) }.joined(separator: " Also: ")).")
        }
        if input.waitingCount > 0 {
            let names = input.waiting.map(\.name).joined(separator: ", ")
            sentences.append("\(input.waitingCount) session\(input.waitingCount == 1 ? " needs" : "s need") you: \(names).")
        }
        return sentences.joined(separator: " ").replacingOccurrences(of: "..", with: ".").replacingOccurrences(of: "?.", with: "?")
    }
}

/// The prompt a briefing is written from.
public enum BriefingPrompts {
    /// The system prompt: words to be heard once, at a glance's level.
    public static let system = """
        You brief a busy person out loud on what their software projects' AI teams did. Plain spoken sentences only: \
        no lists, no markdown, no headings, no greeting. Never say file names, commit hashes, task ids, branch names \
        or code. Stay at the highest level: what landed, what's stuck, what waits on them.
        """

    /// The words it asks for.
    public static let words = 70...90

    public static func prompt(_ input: BriefingInput, language: BriefingLanguage) -> String {
        let hours = max(1, Int(((input.now - input.since) / 3600).rounded()))
        if let project = input.project { return prompt(input, project: project, hours: hours, language: language) }
        return """
            Write a spoken briefing of \(words.lowerBound) to \(words.upperBound) words (about 30 seconds aloud), \
            in \(language.name) (language code \(language.code)), of what happened in the last \(hours) hour\(hours == 1 ? "" : "s") \
            across these projects: what landed, what's stuck, what waits on the user, and which sessions need them. \
            One short sentence per project with news; group the quiet ones in a few words; end with what needs the \
            user, if anything. Numbers as words a listener follows (e.g. "nine fixes landed"). Write the whole \
            briefing in \(language.name), whatever language the notes are in.

            Notes, newest first:
            \(Redaction.secrets(in: input.text))
            """
    }

    /// A project briefing's: the same budget and rules, about one project, ending with its questions for the user.
    static func prompt(_ input: BriefingInput, project: String, hours: Int, language: BriefingLanguage) -> String {
        """
        Write a spoken briefing of \(words.lowerBound) to \(words.upperBound) words (about 30 seconds aloud), \
        in \(language.name) (language code \(language.code)), of what happened in the project \(project) in the last \
        \(hours) hour\(hours == 1 ? "" : "s"): what landed, what's running, what's blocked, and the questions waiting \
        on the user. A few short sentences; if nothing is new, say so in one. End with the questions for the user, \
        each in a few words, and which sessions need them, if any. Numbers as words a listener follows (e.g. "nine \
        fixes landed"). Write the whole briefing in \(language.name), whatever language the notes are in.

        Notes, newest first:
        \(Redaction.secrets(in: input.text))
        """
    }
}

extension ClaudeHeadless {
    /// A briefing takes longer to write than a one-liner.
    public static let briefingTimeout: TimeInterval = 60

    /// The briefing for `prompt` (see `BriefingPrompts`), through the same headless Claude as the one-liners, with
    /// the briefing's system prompt and more time; nil when Claude isn't there, fails or takes too long. Blocks.
    public static func brief(_ prompt: String) -> String? {
        let command = command(prompt: prompt, system: BriefingPrompts.system)
        return run(executable: command.executable, args: command.args, timeout: briefingTimeout)
    }
}
