import Foundation
import VibeCore

/// A new project from the page (`project.new`, the no-terminal inventory's C1): what `vibeswitcher new-project` makes
/// (`ProjectCreation`'s name rules, its folder name and README) and what `lead FOLDER --init` makes of it (`LeadInit`:
/// the repository built privately and installed through the folder's descriptor, its first commit as the user's global
/// identity, no hook or template of anyone's), then the project's lead (`LeadEngine.startLead`, `initialized`).
///
/// The server makes it for whoever the voice let through (a terminal, or a page that acts), so it takes less than the
/// command line does, and refuses anything unusual before it makes anything:
/// - **Only in the projects folder.** The parent is the node's projects folder (`projects_folder`, else `~/dev`) or a
///   folder inside it, named without `.` or `..`; each folder below the projects folder is opened from its parent's
///   descriptor with `O_NOFOLLOW`, so a link on the way (to anywhere, inside or out) refuses. The projects folder itself is
///   the user's setting, taken as it resolves; `/` refuses.
/// - **Never over anything.** The project's folder is made with `mkdirat` on the parent's descriptor: anything with its
///   name there (a folder, a file, a link, a dangling one) refuses. Its README is made `O_CREAT|O_EXCL|O_NOFOLLOW` in it.
/// - **The name as the app's.** `ProjectCreation.plan`'s rules (a letter or number, no `/` or `:`, not hidden), and no
///   control or format character, at most `maxName` characters.
/// - **Nothing left on a refusal.** What was made is removed through the same descriptors (only while it is still what was
///   made); what something else put there meanwhile stays, and the refusal says so.
public enum ProjectMaker {
    /// Why a project wasn't made: `reason` for the page's words, `message` the node's.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public enum Reason: String, Sendable, CaseIterable {
            /// The name breaks a rule of the app's (`ProjectCreation.Problem`), or has a character no folder should.
            case name
            /// The parent isn't the projects folder or a folder inside it.
            case outside
            /// A link on the way below the projects folder.
            case link
            /// Something of the project's folder name is there already.
            case exists
            /// The parent isn't a folder there (missing, or a file).
            case location
            /// No name and email in the user's global git config, for the first commit.
            case identity
            /// The parent is inside a git repository: a project gets one of its own.
            case repository
            /// No claude for the lead: nothing is made for a lead that can't start.
            case noClaude
            /// Anything else: the step that failed says what.
            case failed
        }

        public var reason: Reason
        public var message: String
        public init(_ reason: Reason, _ message: String) {
            self.reason = reason
            self.message = message
        }
        public var description: String { message }
    }

    /// What was made.
    public struct Made: Equatable, Sendable {
        /// The project's name, as typed (trimmed).
        public var name: String
        /// Its folder, by its resolved path.
        public var folder: String
        /// The first commit's id.
        public var commit: String
        /// What the first commit holds.
        public var files: [String]
    }

    /// The longest name taken, in characters.
    public static let maxName = 100

    /// The project `name` made in `location` (nil or empty: the projects folder), under `projectsFolder` (the node's
    /// setting as kept: a tilde path or a full one); `home` the user's (their git identity, `~`); `scratch` the node's
    /// private scratch folder (`LeadInit`'s). Reads and writes the disk and runs git: off the requests' queue.
    public static func make(name: String, location: String?, projectsFolder: String, home: String, scratch: URL) -> Result<Made, Refusal> {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let refused = nameRefusal(title) { return .failure(refused) }
        let folderName = ProjectCreation.folderName(for: title)
        // The name's own rules first, as the app's sheet says them (nothing on the disk is asked yet).
        if case .failure(let problem) = ProjectCreation.plan(name: title, folderName: folderName, location: "/", home: home, existing: { _ in .none }) {
            return .failure(Refusal(.name, problem.message))
        }
        guard folderName.utf8.count <= 255 else { return .failure(Refusal(.name, "The project's name is too long for a folder name.")) }

        // The projects folder, as the user set it (its own links followed: it is their choice), and where in it.
        let root = ProjectCreation.expand(projectsFolder, home: home)
        guard root.hasPrefix("/") else {
            return .failure(Refusal(.failed, "The node's projects folder, \(ConfigSeal.inert(projectsFolder, limit: 200)), isn't a full path: set it again (projects_folder)."))
        }
        let below: [String]
        switch place(location, root: root, home: home) {
        case .failure(let refused): return .failure(refused)
        case .success(let parts): below = parts
        }
        // The projects folder, made when it isn't there yet (only it, and only where it is the parent): as the app makes
        // it for a first project.
        var madeLevels: [String] = []
        if LeadInit.kind(root) == nil {
            guard below.isEmpty else {
                return .failure(Refusal(.location, "\(shown(root, home)) isn't there: make the folder first, or leave Where empty."))
            }
            var missing: [String] = []
            var level = root
            while level != "/", LeadInit.kind(level) == nil {
                missing.insert(level, at: 0)
                level = (level as NSString).deletingLastPathComponent
            }
            for level in missing {
                guard mkdir(level, 0o755) == 0 else {
                    for made in madeLevels.reversed() { rmdir(made) }
                    return .failure(Refusal(.failed, "The projects folder \(shown(root, home)) couldn't be made (errno \(errno))."))
                }
                madeLevels.append(level)
            }
        }
        let undoLevels = { for made in madeLevels.reversed() { rmdir(made) } }

        let top = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard top >= 0 else {
            undoLevels()
            return .failure(Refusal(.location, "The projects folder \(shown(root, home)) isn't a folder that can be opened (errno \(errno))."))
        }
        let real = realPath(top) ?? LeadInit.resolved(root)
        guard real != "/" else {
            close(top)
            undoLevels()
            return .failure(Refusal(.outside, "The projects folder is /: set projects_folder to a folder of its own first."))
        }
        // Each folder below the projects folder, from its parent's descriptor, never through a link.
        var parent = top
        var parentPath = real
        for part in below {
            let next = openat(parent, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            if next < 0 {
                var info = stat()
                let what = fstatat(parent, part, &info, AT_SYMLINK_NOFOLLOW) == 0 ? info.st_mode & S_IFMT : nil
                close(parent)
                undoLevels()
                let at = shown(parentPath + "/" + part, home)
                switch what {
                case S_IFLNK?: return .failure(Refusal(.link, "\(at) is a link: a project is made only in a real folder inside the projects folder."))
                case nil: return .failure(Refusal(.location, "\(at) isn't there."))
                case S_IFDIR?: return .failure(Refusal(.failed, "\(at) couldn't be opened (errno \(failure))."))
                default: return .failure(Refusal(.location, "\(at) is a file, not a folder."))
                }
            }
            close(parent)
            parent = next
            parentPath += "/" + part
        }
        defer { close(parent) }

        // The project's folder: made new, or nothing (anything by its name there refuses, a link too).
        let folder = parentPath + "/" + folderName
        guard mkdirat(parent, folderName, 0o755) == 0 else {
            let failure = errno
            undoLevels()
            if failure == EEXIST {
                var info = stat()
                let isFolder = fstatat(parent, folderName, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFDIR
                return .failure(Refusal(.exists, isFolder ? ProjectCreation.Problem.exists(folder: folderName, location: shown(parentPath, home)).message
                                                          : ProjectCreation.Problem.isFile(name: folderName, location: shown(parentPath, home)).message))
            }
            return .failure(Refusal(.failed, "The project's folder couldn't be made in \(shown(parentPath, home)) (errno \(failure))."))
        }
        var madeInfo = stat()
        let project = openat(parent, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var opened = stat()
        guard fstatat(parent, folderName, &madeInfo, AT_SYMLINK_NOFOLLOW) == 0, project >= 0, fstat(project, &opened) == 0,
              opened.st_dev == madeInfo.st_dev, opened.st_ino == madeInfo.st_ino else {
            if project >= 0 { close(project) }
            undoLevels()
            return .failure(Refusal(.failed, "The project's folder changed as it was made: look at \(shown(folder, home)); nothing of the project was written."))
        }
        defer { close(project) }
        var madeReadme = false
        func undo(_ refusal: Refusal) -> Refusal {
            if madeReadme { unlinkat(project, "README.md", 0) }
            var now = stat()
            let same = fstatat(parent, folderName, &now, AT_SYMLINK_NOFOLLOW) == 0 && now.st_ino == madeInfo.st_ino && now.st_dev == madeInfo.st_dev
            guard same, unlinkat(parent, folderName, AT_REMOVEDIR) == 0 else {
                return Refusal(refusal.reason, refusal.message + " \(shown(folder, home)) stays: something else was put in it meanwhile; look at it before trying again.")
            }
            undoLevels()
            return refusal
        }
        guard LeadInit.Descriptors.create(project, "README.md", Data(ProjectCreation.readme(name: title).utf8), mode: 0o644) else {
            return .failure(undo(Refusal(.failed, "The project's README couldn't be written (errno \(errno)).")))
        }
        madeReadme = true

        return .success(Made(name: title, folder: folder, commit: "", files: ["README.md"]))
    }

    /// Why `title` isn't a name taken here (before the app's own rules): a control or format character (a direction
    /// mark, a zero-width one), or more than `maxName` characters.
    static func nameRefusal(_ title: String) -> Refusal? {
        if title.unicodeScalars.contains(where: { [.control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned].contains($0.properties.generalCategory) }) {
            return Refusal(.name, "A project name can't hold a control or invisible character.")
        }
        guard title.count <= maxName else { return Refusal(.name, "A project name is at most \(maxName) characters.") }
        return nil
    }

    /// The folders below the projects folder `root` that `location` names (none: the projects folder itself), or why
    /// not: not a full path or `~/…`, a `.` or `..`, a character no path should hold, or not inside `root`.
    static func place(_ location: String?, root: String, home: String) -> Result<[String], Refusal> {
        let typed = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return .success([]) }
        if typed.unicodeScalars.contains(where: { [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) }) {
            return .failure(Refusal(.outside, "Where can't hold a control or invisible character."))
        }
        let full = typed == "~" ? home : typed.hasPrefix("~/") ? home + typed.dropFirst(1) : typed
        guard full.hasPrefix("/") else { return .failure(Refusal(.outside, "Where is a full path (/…) or one in your home (~/…).")) }
        let parts = full.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else {
            return .failure(Refusal(.outside, "Where names its folders without “.” or “..”."))
        }
        let base = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // The projects folder by the path it is set as, or the one it resolves to (a person may type either).
        let real = LeadInit.kind(root) == nil ? base : LeadInit.resolved(root).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for prefix in [base, real] where parts.count >= prefix.count && Array(parts.prefix(prefix.count)) == prefix {
            return .success(Array(parts.dropFirst(prefix.count)))
        }
        return .failure(Refusal(.outside, "A project from here is made in your projects folder, \(shown(root, home)), or a folder inside it; \(ConfigSeal.inert(shown(full, home), limit: 200)) isn't."))
    }

    /// The path of the folder `descriptor` is open on, as the system resolves it.
    static func realPath(_ descriptor: Int32) -> String? {
        #if os(Linux)
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(descriptor)")
        #else
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
        #endif
    }

    static func shown(_ path: String, _ home: String) -> String { ProjectCreation.tildePath(path, home: home) }
}

extension Requests {
    /// `project.new` with `name`, `location` (optional: the projects folder) and `goal` (optional, the lead's): the
    /// project made (`ProjectMaker.make`, off the queue), then its lead started as `lead` starts one (`initialized`: its
    /// repository is new, so its hooks baseline is recorded empty first). Nothing is made when the node has no claude
    /// for the lead. A refusal before anything is made is a result (`made` false, `refused` its reason, `said` why), so a
    /// page can say it in its own words; a lead that didn't start after the project was made is said beside it.
    func newProject(_ request: NodeWire.Request, reply: @escaping (NodeWire.Reply) -> Void) {
        let args: WireKinds.ProjectNew.Args
        switch request.typedArgs(WireKinds.ProjectNew.Args.self) {
        case .failure(let failure): return reply(.init(re: request.id, error: failure))
        case .success(let taken): args = taken
        }
        guard let name = args.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return reply(.init(re: request.id, error: .init(.badArgs, "project.new needs name, the project's name")))
        }
        let goal = args.goal.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard let engine else { return reply(.init(re: request.id, error: .init(.refused, "this server starts no leads, so it makes no project"))) }
        let (queue, note, nodeRoot, home) = (self.queue, self.note, root, engine.home)
        let preflight = engine.preflight
        DispatchQueue.global(qos: .userInitiated).async {
            func answer(_ result: WireKinds.ProjectNew.Result) { queue.async { reply(.init(re: request.id, typed: result)) } }
            // Nothing is made for a lead the engine would refuse to start.
            if case .failure(let missing) = preflight.check() {
                return answer(Self.projectRefused(.init(.noClaude, "No claude for the project's lead (\(missing.missing.joined(separator: "; "))): nothing was made.")))
            }
            let folder = NodeSettings.projectsFolder(files: NodeSettings.Files(root: nodeRoot))
            let made: ProjectMaker.Made
            switch ProjectMaker.make(name: name, location: args.location, projectsFolder: folder, home: home,
                                     scratch: nodeRoot.appendingPathComponent("scratch", isDirectory: true)) {
            case .failure(let refusal):
                note("project.new: nothing made: \(refusal.reason.rawValue)")
                return answer(Self.projectRefused(refusal))
            case .success(let done): made = done
            }
            note("project.new: made \(ConfigSeal.inert(made.folder, limit: 200)) with its first commit \(made.commit.prefix(8)); starting its lead")
            engine.startLead(folder: made.folder, goal: goal, takeHead: false, replace: false, initialized: false) { outcome in
                answer(Self.projectMade(made, home: home, outcome))
            }
        }
    }

    /// A project not made: its reason, and why in the node's words.
    static func projectRefused(_ refusal: ProjectMaker.Refusal) -> WireKinds.ProjectNew.Result {
        WireKinds.ProjectNew.Result(made: false, name: nil, folder: nil, commit: nil, lead: nil, session: nil, refused: refusal.reason.rawValue,
                                    said: refusal.message, notes: [])
    }

    /// A project made, and what its lead's start did, in a sentence a person reads.
    static func projectMade(_ made: ProjectMaker.Made, home: String, _ outcome: LeadEngine.StartOutcome) -> WireKinds.ProjectNew.Result {
        let shown = ConfigSeal.inert(ProjectCreation.tildePath(made.folder, home: home), limit: 200)
        let name = ConfigSeal.inert(made.name, limit: 200)
        let what = "“\(name)” is made in \(shown), with its git repository and first commit"
        func result(_ lead: String, session: UUID?, said: String, notes: [String]) -> WireKinds.ProjectNew.Result {
            WireKinds.ProjectNew.Result(made: true, name: made.name, folder: made.folder, commit: made.commit, lead: lead,
                                        session: session.map { NodeIds.session(host: $0) }, refused: nil, said: said, notes: notes)
        }
        switch outcome {
        case .started(let session, _, let notes): return result("started", session: session, said: what + "; its lead started.", notes: notes)
        case .shown(let session, let notes): return result("shown", session: session, said: what + "; its lead runs.", notes: notes)
        case .waiting: return result("waiting", session: nil, said: what + "; its lead starts once the node's link to its host is ready.", notes: [])
        case .refused(let why):
            return result("refused", session: nil, said: what + ", but its lead didn't start: \(ConfigSeal.inert(why, limit: 400))", notes: [why])
        }
    }
}
