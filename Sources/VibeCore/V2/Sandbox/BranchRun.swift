import Foundation

/// A branch run in a box of its own (the session sandbox plan's SB6): what `BranchCode.wrapper` runs (a merge's tests,
/// an audit's shared run, `init_command`, a verifier's command) goes through a **launcher**, which enters a
/// `branchRun` plan and runs the wrapper inside it. In that box there is no door, no host socket, no terminal and no
/// network, only the run's own processes, and nothing is written but the run's scratch worktree and scratch home
/// (the plan's table, "What each role can read, write, run and reach").
///
/// - **The launcher** is the tool server's image, started as a fresh process with `flag` as its first argument: its
///   main's first statement is `execIfLaunched`, so it has one thread and has run none of the server's code when it
///   enters. It plans the box itself, from its request and its own environment (`plan`), makes the folders the plan
///   names, and enters (`Platform.Sandbox.enter`): from then on it is the box's keeper, and exits as the command did.
/// - **Its request** is its arguments, in fixed places: `flag`, the folder the command runs in, the run's scratch
///   home, the account's home, the project's settings for its boxes, then the wrapped command, word for word
///   (`Request`). None of it is secret, and no plan travels: `command`'s `keep` is empty.
/// - **It fails closed.** A request that isn't whole, a box that can't be planned, a folder that can't be made, a
///   plan that can't be entered: the launcher says which on stderr and exits `refused`, having run nothing. The
///   wrapper alone is what runs only where no box can be built (`Platform.Sandbox.probe()` says why) and on the Mac.
/// - **Who starts one** (`launching`, the hook in `Shell.run(branchCode:)` and `BranchCode.runPrefix`): a process
///   whose main ran `execIfLaunched`, the tool server, with its own image; and a test that names a launcher
///   (`with`). Any other process (a test binary on its own, the app) has no image that knows `flag`, and runs the
///   wrapper as it always did. Every branch run of a node is its tool servers'.
///
/// The Mac has no box: `command` and `launching` give the wrapped command back there, whatever else they are given.
public enum BranchRun {
    /// The launcher's first argument.
    public static let flag = "--branch-run"
    /// What a launcher that started nothing exits with (a shell's "found, but couldn't be run").
    static let refused: Int32 = 126
    /// The folder, beside a run's scratch home, that holds the runs' layers (`plan`).
    static let runsFolder = ".branch-runs"
    /// A verifier's command's scratch home, in its session's TMPDIR: its own HOME is the account's, which no box shows.
    static let verifierHome = "branch-run-home"
    /// The names a run is given on top of what any box passes on (`SandboxPlanner.allowed`): the slot its run holds
    /// outside, that slot's width and the slots' folder (`TestLock`), so a script of the branch's that would take a
    /// slot itself (`vs-heavy`) knows its run holds one, and doesn't wait for a file it can't see.
    static let passed = [TestLock.heldVariable, TestLock.coresVariable, TestLock.directoryVariable]

    /// A run's TMPDIR: `tmp` in its scratch home, as `Worktrees.runChecks` makes it.
    static func temporary(in home: String) -> String { home + "/tmp" }

    // MARK: The command

    /// What to start for `wrapped` (`BranchCode.wrapper` and its command) in `cwd`, with `home` as the run's scratch
    /// home: the launcher at `server` with its request, or, where no box can be built (`facts.why`) and on the Mac,
    /// `wrapped` as it is. With the project's `sandbox: off` (`policy.enabled` false), where a box could be built:
    /// `wrapped` plain, saying so first (`plain`). `keep`: the descriptors the launcher must inherit, none in this
    /// slice (a proxied run's listener line, from slice 2).
    public static func command(_ wrapped: [String], cwd: String, home: String, policy: SandboxPolicy, server: String,
                               facts: Platform.Sandbox.Facts) -> (executable: String, arguments: [String], keep: [Int32]) {
        command(wrapped, cwd: cwd, home: home, policy: policy, server: server, facts: facts, accountHome: VibePaths.home,
                onTheMac: Platform.CodeIdentity.isAvailable)
    }

    /// `command`, with the account's home named (the public form's: this process's own) and the system said.
    static func command(_ wrapped: [String], cwd: String, home: String, policy: SandboxPolicy, server: String,
                        facts: Platform.Sandbox.Facts, accountHome: String, onTheMac: Bool)
        -> (executable: String, arguments: [String], keep: [Int32]) {
        guard !onTheMac, facts.why == nil, !wrapped.isEmpty else { return (wrapped.first ?? "", wrapped, []) }
        guard policy.enabled else {
            let plain = plain(wrapped)
            return (plain[0], plain, [])
        }
        let request = Request(cwd: cwd, home: home, accountHome: accountHome, policy: policy, wrapped: wrapped)
        return (server, [server] + request.arguments, [])
    }

    /// Whether `argv` starts a launcher.
    static func isLauncher(_ argv: [String]) -> Bool { argv.count > 1 && argv[1] == flag }

    /// A launcher's request, as its arguments carry it: after the program's name, `flag`, the folder the command runs
    /// in, the run's scratch home, the account's home, the project's settings as JSON, then the wrapped command. The
    /// places are fixed and nothing is looked for: a word of the command that reads like an option is the command's.
    struct Request: Equatable {
        var cwd: String
        var home: String
        /// Where the caches and the node's folder are looked for, and whose hidden folders the plan is judged by: the
        /// home the starting process was given (`VibePaths.home`). The launcher judges by the user database's too.
        var accountHome: String
        var policy: SandboxPolicy
        var wrapped: [String]

        init(cwd: String, home: String, accountHome: String, policy: SandboxPolicy, wrapped: [String]) {
            self.cwd = cwd
            self.home = home
            self.accountHome = accountHome
            self.policy = policy
            self.wrapped = wrapped
        }

        /// The words before the wrapped command, the program's name among them.
        static let fixed = 6

        /// From a launcher's `arguments` (its program's name first); nil when they aren't a whole request.
        init?(arguments: [String]) {
            guard arguments.count > Self.fixed, arguments[1] == BranchRun.flag,
                  let policy = try? JSONDecoder().decode(SandboxPolicy.self, from: Data(arguments[5].utf8)) else { return nil }
            self.init(cwd: arguments[2], home: arguments[3], accountHome: arguments[4], policy: policy,
                      wrapped: Array(arguments[Self.fixed...]))
        }

        /// The launcher's arguments after its program's name.
        var arguments: [String] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let settings = (try? encoder.encode(policy)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return [BranchRun.flag, cwd, home, accountHome, settings] + wrapped
        }
    }

    // MARK: Who starts a launcher

    /// What a thread's branch runs are started with, in place of this process's own (`with`): the launcher's image,
    /// the account's home, the project's settings for its boxes. Each nil: this process's own (its image when it is
    /// the tool server, `VibePaths.home`), and for the settings `SandboxPolicy.standard`.
    ///
    /// The settings reach a run only this way: neither `Shell.run` nor a verifier's prefix knows the project, and this
    /// type never reads `workflow.md` itself, whose `sandbox*` keys count only as the vault holds them accepted
    /// (`LeadVault.sandboxPolicy`). The lead's tools set them around the runs they start (`with(policy:)`: where a
    /// branch's code is marked as running, `LeadToolset.markBranchRun`, and the pre-done check); any other run's box is
    /// the standard one.
    ///
    /// `refusal`: the project's settings couldn't be read (a key that names a hidden folder, the vault unreadable):
    /// a run that would be boxed starts nothing then, and says why (`launching`).
    struct Scope {
        var launcher: String?
        var accountHome: String?
        var policy = SandboxPolicy.standard
        var refusal: SandboxRefusal?
    }

    private static let scopeKey = "VibeCore.BranchRun.scope"

    /// The scope `with` gave this thread.
    static var scope: Scope? { Thread.current.threadDictionary[scopeKey] as? Scope }

    /// The account home this thread's runs are planned and judged by: its scope's, else the account's own
    /// (`VibePaths.accountHome`, which no environment moves). What the project's paths are read against.
    static var accountHome: String { scope?.accountHome ?? VibePaths.accountHome }

    /// Runs `body` with the project's settings `policy` (`LeadVault.sandboxPolicy`'s) for the branch runs it starts on
    /// this thread, the rest of this thread's scope (a launcher a test named, its account home) kept.
    static func with<T>(policy: Result<SandboxPolicy, SandboxRefusal>, _ body: () throws -> T) rethrows -> T {
        try with(scoped(policy), body)
    }

    /// This thread's scope with `policy` in it.
    static func scoped(_ policy: Result<SandboxPolicy, SandboxRefusal>) -> Scope {
        var scope = self.scope ?? Scope()
        switch policy {
        case .success(let read): (scope.policy, scope.refusal) = (read, nil)
        case .failure(let refusal): (scope.policy, scope.refusal) = (.standard, refusal)
        }
        return scope
    }

    private static let enteredKey = "VibeCore.BranchRun.entered"

    /// A scope this thread had before an `enter` (none: `nil`), as the stack keeps it.
    private struct Before { var scope: Scope? }

    /// `with(policy:)` for a span that isn't one closure (a mark and its end, `LeadToolset.markBranchRun`): the
    /// thread's scope until its `leave`, on the same thread. Spans nest; each `leave` gives back what its `enter` found.
    static func enter(policy: Result<SandboxPolicy, SandboxRefusal>) {
        let dictionary = Thread.current.threadDictionary
        dictionary[enteredKey] = ((dictionary[enteredKey] as? [Before]) ?? []) + [Before(scope: scope)]
        dictionary[scopeKey] = scoped(policy)
    }

    /// Ends this thread's last `enter`: its scope is what that found. Nothing when none is open.
    static func leave() {
        let dictionary = Thread.current.threadDictionary
        guard var stack = dictionary[enteredKey] as? [Before], let before = stack.popLast() else { return }
        dictionary[enteredKey] = stack.isEmpty ? nil : stack
        if let scope = before.scope { dictionary[scopeKey] = scope } else { dictionary.removeObject(forKey: scopeKey) }
    }

    /// Runs `body` with `scope` for the branch runs it starts on this thread (nil: with none), as `ShellCancel.with`
    /// gives a thread its cancel.
    static func with<T>(_ scope: Scope?, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let before = dictionary[scopeKey]
        if let scope { dictionary[scopeKey] = scope } else { dictionary.removeObject(forKey: scopeKey) }
        defer {
            if let before { dictionary[scopeKey] = before } else { dictionary.removeObject(forKey: scopeKey) }
        }
        return try body()
    }

    /// This process's image as a launcher, once its main ran `execIfLaunched`: the running image itself where the
    /// system names it (`ServerBuildLinux.selfImage`: the same build even after another is installed at its path, and
    /// for an image started from a sealed copy, whose path names nothing), else the path it was started from.
    private final class Own: @unchecked Sendable {
        private let lock = NSLock()
        private var started: String?
        private var found: String?

        func set(_ path: String) { lock.withLock { started = path } }

        var launcher: String? {
            lock.withLock {
                guard let started else { return nil }
                if found == nil {
                    found = access(ServerBuildLinux.selfImage, X_OK) == 0 ? ServerBuildLinux.selfImage : (Bundle.main.executablePath ?? started)
                }
                return found
            }
        }
    }

    private static let own = Own()

    /// The hook where `BranchCode.wrapper` is run (`Shell.run(branchCode:)`, `BranchCode.runPrefix`): what to start
    /// for `wrapped` in `directory` with `environment`, its argv, the program first. The launcher (`command`) when this
    /// thread was told one or this process is the tool server, and a box can be built; else `wrapped` as it is.
    ///
    /// The run's scratch home is the one its caller made, `CFFIXED_USER_HOME` (`Worktrees.runChecks`); for a command
    /// that has the account's own (a verifier's), `verifierHome` in its TMPDIR; with neither, none, which the launcher
    /// refuses. `facts`: nil for this machine's, asked only once a launcher is known.
    ///
    /// The scope's settings: refused (`Scope.refusal`), the run starts nothing, boxed or not, and says which key on
    /// stderr, exiting `refused`; `sandbox: off`, the wrapper runs plain, saying so first (`command`).
    static func launching(_ wrapped: [String], in directory: String, environment: [String: String],
                          facts: Platform.Sandbox.Facts? = nil, onTheMac: Bool = Platform.CodeIdentity.isAvailable) -> [String] {
        let scope = self.scope
        if let refusal = scope?.refusal, !wrapped.isEmpty { return refusing(refusal) }
        guard !onTheMac, let launcher = scope?.launcher ?? own.launcher else { return wrapped }
        let account = scope?.accountHome ?? VibePaths.home
        let facts = facts ?? Platform.Sandbox.probe()
        return command(wrapped, cwd: directory, home: home(environment, account: account), policy: scope?.policy ?? .standard,
                       server: launcher, facts: facts, accountHome: account, onTheMac: onTheMac).arguments
    }

    // MARK: A verifier's commands

    /// The variable a verifier's session carries its project's settings in, fixed when the tool server started it
    /// (`LeadLaunch.prepare`'s `box`, read by `LeadVault.sandboxPolicy` as for the tool server's own runs): its shell
    /// prefix (`BranchCode.runPrefix`), the tool server's binary started once per command, boxes each command by them.
    /// It is in the verifier's `--settings` file and its process's environment, which its commands can't write: they
    /// run in their box, where neither is (the file is in the vault's run folder, the process outside the box's pid
    /// namespace), and a command that sets it for another prefix it starts inside changes no more than its own box
    /// shows. A policy accepted after the verifier started doesn't reach it.
    public static let policyVariable = "VIBESWITCHER_BRANCH_RUN_POLICY"

    /// `policy` as `policyVariable` carries it: JSON, the settings or their refusal.
    public static func carried(_ policy: Result<SandboxPolicy, SandboxRefusal>) -> String {
        let carried: Carried
        switch policy {
        case .success(let read): carried = Carried(policy: read)
        case .failure(let refusal): carried = Carried(refusal: .init(key: refusal.key, value: refusal.value, reason: refusal.reason))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(carried)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What `policyVariable`'s `value` carries: none, the standard settings (a verifier started before it was set);
    /// one that can't be read, a refusal, so its runs start nothing.
    public static func carried(from value: String?) -> Result<SandboxPolicy, SandboxRefusal> {
        guard let value else { return .success(.standard) }
        let read = try? JSONDecoder().decode(Carried.self, from: Data(value.utf8))
        if let policy = read?.policy, read?.refusal == nil { return .success(policy) }
        if let refusal = read?.refusal, read?.policy == nil { return .failure(SandboxRefusal(key: refusal.key, value: refusal.value, reason: refusal.reason)) }
        return .failure(SandboxRefusal(value: policyVariable, reason: "the settings this verifier was started with can't be read"))
    }

    private struct Carried: Codable {
        struct Refusal: Codable {
            var key: String?
            var value: String
            var reason: String
        }
        var policy: SandboxPolicy?
        var refusal: Refusal?
    }

    /// `environment`, for a run this thread starts, with what the project's settings tell its tools (`sandbox_env`):
    /// its variables, and its folders first on the PATH (the PATH given, else this process's). Boxed or not: a run's
    /// home is a scratch one (`Worktrees.runChecks`), where a tool installed in the account finds nothing of itself
    /// even with no box. A box passes them on by its own plan (`plan`), its allow-list dropping what a launcher was
    /// given. As given when this thread has no such settings.
    static func tools(_ environment: [String: String], inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        guard let policy = scope?.policy, scope?.refusal == nil, !(policy.environment.isEmpty && policy.path.isEmpty) else { return environment }
        var given = environment.merging(policy.environment) { $1 }
        if !policy.path.isEmpty {
            given["PATH"] = (policy.path + [environment["PATH"] ?? inherited["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        }
        return given
    }

    /// What starts in place of a run whose project's settings were refused: a shell that says so and exits `refused`.
    static func refusing(_ refusal: SandboxRefusal) -> [String] {
        ["/bin/sh", "-c", "printf '%s\\n' \"$0\" >&2; exit \(refused)",
         "vibeswitcher: this branch run wasn't started: the project's settings for its box are refused (workflow.md's \(refusal)). Nothing of it ran."]
    }

    /// The line a run with `sandbox: off` says first.
    static let plainNotice = "vibeswitcher: this branch run is in no box: the project's workflow.md says sandbox: off, as the user accepted it."

    /// `wrapped`, plain, saying `plainNotice` on stderr first: inside the wrapper when it starts with it (so what runs is
    /// still known for the wrapper's, `BranchCode.isRunner`), else before it.
    static func plain(_ wrapped: [String]) -> [String] {
        let say = ["/bin/sh", "-c", "printf '%s\\n' \"$0\" >&2; exec \"$@\"", plainNotice]
        let wrapper = wrapped.starts(with: BranchCode.wrapper) ? BranchCode.wrapper.count : 0
        return Array(wrapped.prefix(wrapper)) + say + wrapped.dropFirst(wrapper)
    }

    /// The run's scratch home, from the environment it is started with (see `launching`); empty for none.
    static func home(_ environment: [String: String], account: String) -> String {
        // By their spelling (`SandboxPolicy.lexical`), as the planner tidies its paths.
        if let given = environment["CFFIXED_USER_HOME"], given.hasPrefix("/"), SandboxPolicy.lexical(given) != SandboxPolicy.lexical(account) {
            return given
        }
        guard let temporary = environment["TMPDIR"], temporary.hasPrefix("/") else { return "" }
        let folder = SandboxPolicy.lexical(temporary)
        return (folder == "/" ? "" : folder) + "/" + verifierHome
    }

    // MARK: The launcher

    /// The tool server's main's first statement. Started with `flag`, this process is a launcher and never returns
    /// from here: it plans its request's box, makes its folders and enters it, becoming the box's keeper, or says why
    /// not and exits `refused`. Started any other way, it returns at once, having noted that this process's image can
    /// be a launcher (`launching`).
    public static func execIfLaunched(_ arguments: [String]) {
        guard isLauncher(arguments) else {
            own.set(arguments.first ?? "")
            return
        }
        func refuse(_ why: String) -> Never {
            // Whoever would read it may have gone: the write fails then, and this still ends as refused.
            signal(SIGPIPE, SIG_IGN)
            FileHandle.standardError.write(Data("vibeswitcher: this branch run wasn't started: \(why). Nothing of it ran.\n".utf8))
            exit(refused)
        }
        guard let request = Request(arguments: arguments) else { refuse("its box's launcher was given no whole request") }
        let planned: Planned
        switch plan(request, environment: ProcessInfo.processInfo.environment, image: Bundle.main.executablePath) {
        case .failure(let refusal): refuse("its box can't be planned (\(refusal))")
        case .success(let made): planned = made
        }
        // What ended runs left beside this one. It never keeps this run from starting (`sweep`).
        say(setAside: sweep((planned.layers as NSString).deletingLastPathComponent))
        for folder in planned.folders {
            do {
                try VibePaths.ensurePrivate(URL(fileURLWithPath: folder, isDirectory: true))
            } catch {
                refuse("its box's folder \(folder) can't be made (\(error.localizedDescription))")
            }
        }
        // Returns only when nothing was started.
        let failure = Platform.Sandbox.enter(planned.plan, doorLine: nil, proxyOut: nil, program: request.wrapped)
        refuse("its box couldn't be entered (\(failure))")
    }

    /// A run's box, and what the launcher makes before it enters.
    struct Planned {
        var plan: Platform.Sandbox.Plan
        /// The folders to make (each with what is above it), 0700: the run's home and TMPDIR, and each layer's two.
        var folders: [String]
        /// This run's own folder for its layers, in `runsFolder` beside its home: `<pid>-<id>`.
        var layers: String
    }

    /// The box of `request`'s run, planned as a branch run's (`SandboxPlanner`, role `branchRun`) from the launcher's
    /// `environment` and `image` (its own executable: the node's build folder is where that is). It reads files only
    /// to see what is there, and makes nothing.
    ///
    /// - The worktree is the folder at or above `request.cwd` that has a `.git` (a worktree's pointer file, by
    ///   `GitRoots`), the project the repository it belongs to; the command starts in `cwd` itself. A folder in no
    ///   worktree is refused.
    /// - The home is `request.home`, its TMPDIR `tmp` in it; neither need be there yet.
    /// - Sources in the node's folder: a merge's scratch worktree and home are there (`LeadVault.scratch`), beside
    ///   each other, and the planner shows nothing of that folder but the node's build, the installed hook and the
    ///   box's own folder. So when the home's parent is the vault's scratch space for one project
    ///   (`<node>/lead/scratch/<key>`), that parent is the run's own folder to the planner: a worktree beside the home
    ///   passes, and one anywhere else in the node's folder is refused, as is a home anywhere else there.
    /// - The home's parent, and the home when it is there, must be a folder of this user's that nobody else can
    ///   write, no link (`isOwnFolder`): a TMPDIR that is the shared `/tmp` refuses the run.
    /// - The layers of its package caches go in `<home's parent>/.branch-runs/<run>`, never in the home: the kernel
    ///   leaves a layer's work folder behind with no mode at all, which whoever removes the home when the run is over
    ///   (`Worktrees.rebaseAndTest`) couldn't remove. What a run leaves there goes at the next run beside it (`sweep`).
    /// - Judged twice: by `request.accountHome`, and by `realHome` (the user database's, which no environment moves),
    ///   so a process started with another HOME still shows nothing the real account hides. A PATH folder either
    ///   refuses is left out, as the planner leaves one out; any other source refuses the plan.
    /// - Its environment is the plan's (an allow-list), with `passed`, `CFFIXED_USER_HOME` (the home, as `runChecks`
    ///   gives it today) and the variables the project's `sandbox_env` names (`SandboxPolicy.environment`).
    /// - Its PATH: the folders the project's `sandbox_env` puts first (`SandboxPolicy.path`), then the launcher's own,
    ///   each shown read-only as the planner shows a PATH folder.
    static func plan(_ request: Request, environment: [String: String], image: String?, realHome: String = VibePaths.accountHome,
                     run: String = "\(getpid())-\(UUID().uuidString.prefix(8))") -> Result<Planned, SandboxRefusal> {
        func refuse(_ value: String, _ reason: String) -> Result<Planned, SandboxRefusal> {
            .failure(SandboxRefusal(value: value, reason: reason))
        }
        guard request.home.hasPrefix("/") else {
            return refuse(request.home.isEmpty ? "its home" : request.home,
                          "a branch run needs a scratch home, and it was given none (no CFFIXED_USER_HOME of its own, no TMPDIR to make one in)")
        }
        guard request.cwd.hasPrefix("/"), request.accountHome.hasPrefix("/") else {
            return refuse(request.cwd, "a branch run's folders are absolute paths")
        }
        let cwd = SandboxPolicy.resolved(request.cwd)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isFolder), isFolder.boolValue else {
            return refuse(request.cwd, "isn't a folder")
        }
        guard let worktree = worktree(holding: cwd) else {
            return refuse(request.cwd, "isn't in a worktree: a branch run's box is planned from one, and nothing ran outside one")
        }
        let roots: GitRoots.Roots
        switch GitRoots.read(worktree: worktree) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let found): roots = found
        }
        let home = settled(request.home), account = settled(request.accountHome), real = settled(realHome)
        let parent = (home as NSString).deletingLastPathComponent
        guard home != "/", parent != "/" else { return refuse(request.home, "is no folder of a run's own") }
        // Where the home and the layers go is this user's alone. In a folder others can write (a shared /tmp as TMPDIR)
        // someone else could put a home of their own making there, or swap what `sweep` removes.
        guard isOwnFolder(parent) else {
            return refuse(parent, "isn't a folder of this user's alone: a branch run's home and layers aren't put where anyone else can write")
        }
        var info = stat()
        if lstat(home, &info) == 0, !isOwnFolder(home) { return refuse(home, "isn't a folder of this user's alone") }
        let layers = parent + "/" + runsFolder + "/" + run
        let variables = environment.map { "\($0.key)=\($0.value)" }.sorted()

        func inputs(_ accountHome: String, path: [String]) -> SandboxInputs {
            // The vault's scratch space for one project (`LeadVault.scratch`: `<node>/lead/scratch/<key>`), when the
            // home is in it, is the run's own folder; anywhere else only its layers are, so nothing else of the node's
            // folder passes for a run's.
            let scratch = accountHome + "/.vibeswitcher/lead/scratch"
            let box = (parent as NSString).deletingLastPathComponent == scratch ? parent : layers
            return SandboxInputs(role: .branchRun, home: home, accountHome: accountHome, uid: getuid(), gid: getgid(),
                                 root: (roots.common as NSString).deletingLastPathComponent, worktree: worktree,
                                 temporary: temporary(in: home), build: build(image), pathFolders: path, agentProgram: nil, box: box,
                                 policy: request.policy, network: .none, slots: nil, environment: variables)
        }
        var path = request.policy.path + (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        if real != account {
            let judge = inputs(real, path: [])
            // Each by the spelling the planner would show it by.
            path = path.filter { SandboxPlanner.sourceRefusal(SandboxPolicy.lexical($0), judge) == nil }
        }
        let planned = inputs(account, path: path)
        var plan: Platform.Sandbox.Plan
        switch SandboxPlanner.plan(planned) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let made): plan = made
        }
        guard plan.door == nil, plan.terminal == .none, plan.network == .none else {
            return refuse(worktree, "its plan isn't a branch run's (a door, a terminal or a network)")
        }

        // Where the command starts, and the layers in the run's own folder.
        plan.directory = cwd
        var folders = [temporary(in: home)]
        let made = planned.box + "/layers/"
        plan.mounts = plan.mounts.map { entry in
            guard case .overlay(let lower, let upper, let work) = entry.kind else { return entry }
            func placed(_ folder: String) -> String {
                folder.hasPrefix(made) ? layers + "/layers/" + folder.dropFirst(made.count) : folder
            }
            folders += [placed(upper), placed(work)]
            return Platform.Sandbox.Mount(entry.target, .overlay(lower: lower, upper: placed(upper), work: placed(work)))
        }
        if real != account {
            let judge = inputs(real, path: path)
            for source in sources(plan) {
                if let refusal = SandboxPlanner.sourceRefusal(source, judge) { return .failure(refusal) }
            }
        }
        plan.environment += passed.compactMap { name in environment[name].map { "\(name)=\($0)" } } + ["CFFIXED_USER_HOME=\(home)"]
        // The tools the project names (`sandbox_env`): told where they are, as the account's home has them.
        plan.environment += request.policy.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return .success(Planned(plan: plan, folders: folders, layers: layers))
    }

    /// The real folders and files `plan` shows.
    static func sources(_ plan: Platform.Sandbox.Plan) -> [String] {
        plan.mounts.flatMap { entry -> [String] in
            switch entry.kind {
            case .readOnly(let source), .readWrite(let source): return [source]
            case .overlay(let lower, let upper, let work): return [lower, upper, work]
            default: return []
            }
        }
    }

    /// The folder at or above `folder` that has a `.git` (whatever it is: `GitRoots` judges it); nil when none has.
    static func worktree(holding folder: String) -> String? {
        var at = folder
        while true {
            var info = stat()
            if lstat((at == "/" ? "" : at) + "/.git", &info) == 0 { return at }
            guard at != "/", !at.isEmpty else { return nil }
            at = (at as NSString).deletingLastPathComponent
        }
    }

    /// `path`, tidied by its spelling (`SandboxPolicy.lexical`), with its links followed as far as it exists, and what
    /// isn't there yet after that as it is spelled: the path a folder made there will have.
    static func settled(_ path: String) -> String {
        var at = SandboxPolicy.lexical(path)
        var rest: [String] = []
        var info = stat()
        while at != "/", !at.isEmpty, lstat(at, &info) != 0 {
            rest.insert((at as NSString).lastPathComponent, at: 0)
            at = (at as NSString).deletingLastPathComponent
        }
        let base = SandboxPolicy.resolved(at.isEmpty ? "/" : at)
        return rest.isEmpty ? base : (base == "/" ? "" : base) + "/" + rest.joined(separator: "/")
    }

    /// The node's build folder, from the launcher's own executable: `<build>/bin/<it>`, else the folder it is in. A
    /// path that names nothing when the executable isn't a file at a path (an image started from a sealed copy, whose
    /// name is no path) or is in no folder of its own: never `/` nor an empty path, which every path is under, so the
    /// planner would take the whole node's folder for the build.
    static func build(_ image: String?) -> String {
        let unknown = "/nonexistent/vibeswitcher/build"
        guard let image, image.hasPrefix("/") else { return unknown }
        let real = SandboxPolicy.resolved(image)
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return unknown }
        let folder = (real as NSString).deletingLastPathComponent
        let build = (folder as NSString).lastPathComponent == "bin" ? (folder as NSString).deletingLastPathComponent : folder
        return build.isEmpty || build == "/" ? unknown : build
    }

    // MARK: What a run leaves

    /// Whether `path` is a folder (no link) of this user's that neither its group nor others can write.
    static func isOwnFolder(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }

    /// Removes what ended runs left in `folder` (a `runsFolder`): each `<pid>-<id>` whose launcher is gone (`alive`:
    /// whether a process has that pid; one that does is left, whoever it is now). A run's layers can't be removed by
    /// the run (its launcher becomes the keeper and exits as the command does), so each launcher takes the ones before
    /// it: at most the last run's stay. Nothing is done in a folder that isn't this user's alone (`isOwnFolder`), and
    /// everything is reached from the folder's own descriptor, no link followed: a link a run planted in its layer is
    /// removed as the link it is.
    ///
    /// It never stops the run it comes before. However deep a run made its tree, this holds four descriptors at most
    /// (this folder's, and `remove`'s three) and calls nothing in itself. And a run's folder it can't remove whole is set aside, renamed
    /// `asidePrefix` and its name, which no sweep takes for a run's: it is tried once, not before every run from then
    /// on. The paths of those are what this gives back, for its caller to say (`say(setAside:)`).
    @discardableResult
    static func sweep(_ folder: String, alive: (pid_t) -> Bool = { kill($0, 0) == 0 || errno != ESRCH },
                      removing: Removing = { unlinkat($0, $1, $2) }) -> [String] {
        guard isOwnFolder(folder) else { return [] }
        let fd = open(folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        defer { Sys.close(fd) }
        var aside: [String] = []
        for entry in names(in: fd) {
            let name = String(cString: entry)
            guard let dash = name.firstIndex(of: "-"), let pid = pid_t(name[..<dash]), pid > 0, pid != getpid(), !alive(pid) else { continue }
            guard !remove(entry, in: fd, removing) else { continue }
            // Should even that fail, it stays under its own name and the next sweep tries it again.
            let kept = asidePrefix + name
            aside.append(folder + "/" + (renameat(fd, entry, fd, kept) == 0 ? kept : name))
        }
        return aside
    }

    /// What takes a name out of the folder a descriptor is open on (`unlinkat`: the folder, the name, its flags).
    typealias Removing = (Int32, UnsafePointer<CChar>, Int32) -> Int32
    /// What the name of a run's folder that was set aside starts with.
    static let asidePrefix = "aside-"

    /// `sweep`, by whoever started the launcher `argv` and has seen it end (a verifier's prefix,
    /// `BranchCodeSession`): its run's layers go now, not at the next run beside it, so a session whose last command
    /// this was leaves none in its TMPDIR, which is removed whole when the session is. Nothing for any other `argv`.
    static func sweep(after argv: [String]) {
        guard isLauncher(argv), let request = Request(arguments: argv), request.home.hasPrefix("/") else { return }
        say(setAside: sweep((settled(request.home) as NSString).deletingLastPathComponent + "/" + runsFolder))
    }

    /// Says on stderr which folders a sweep set aside (`sweep`). It never ends this process: a reader that has gone
    /// is nothing to it, and the signal for one is as it was afterwards (an ignored one would stay ignored in the
    /// command a launcher becomes).
    static func say(setAside left: [String]) {
        guard !left.isEmpty else { return }
        let before = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, before) }
        for path in left {
            let line = "vibeswitcher: what an earlier branch run left in \(path) couldn't be removed. It is set aside there, and this run isn't held up by it.\n"
            _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
        }
    }

    /// The names in the folder `fd` is open on, each as the bytes it is (a name needn't be text), with its ending 0.
    private static func names(in fd: Int32) -> [[CChar]] {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return [] }
        guard let listing = fdopendir(copy) else {
            Sys.close(copy)
            return []
        }
        defer { closedir(listing) }
        // From its start: the copy reads where `fd` was left, which is the end once it has been listed.
        rewinddir(listing)
        var names: [[CChar]] = []
        while let entry = readdir(listing) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { field in
                field.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: field.pointee)) {
                    Array(UnsafeBufferPointer(start: $0, count: strlen($0) + 1))
                }
            }
            if name != [46, 0] && name != [46, 46, 0] { names.append(name) }
        }
        return names
    }

    /// Opens the folder `name` in the folder `folder` is open on, as the folder that was looked at (`info`): no link,
    /// the same file. With its owner's rights from then on: a layer's work folder is left with no mode at all, and a
    /// folder a run made read-only (a module cache's) could be neither emptied nor moved. nil when it can't be, with
    /// `errno` the open's own when that is what failed (`ENOENT`: it has gone meanwhile).
    private static func entered(_ name: [CChar], in folder: Int32, _ info: stat) -> Int32? {
        var fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == EACCES {
            // Never through a link: one put there since the look is left as it is (the call refuses it), and the
            // open below, which follows none either, then fails.
            fchmodat(folder, name, 0o700, AT_SYMLINK_NOFOLLOW)
            fd = openat(folder, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { return nil }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else {
            Sys.close(fd)
            errno = ELOOP
            return nil
        }
        if opened.st_mode & 0o700 != 0o700 { fchmod(fd, 0o700) }
        return fd
    }

    /// Removes the run's folder `name` in the folder `runs` is open on, and all in it. Whether nothing of it is left.
    ///
    /// The tree is flattened as it goes, never walked down: a folder found in the one being emptied is moved up into
    /// the run's folder, under a number, and emptied in its turn. So whatever tree a run made, thousands of folders
    /// deep, this holds three descriptors at most (the run's folder, the folder being emptied, and that one's listing
    /// or a folder being given its owner's rights) and never calls itself. Each thing is reached by its one name from
    /// one of those descriptors, never by a path and never upwards, and no link is followed: what turns out to be no
    /// folder, a link among it, is removed as what it is. What can't be removed is passed over, and the run's folder
    /// then stays (`sweep` sets it aside).
    ///
    /// Another sweep may be at the same folder (two launchers started beside each other): what that one took first is
    /// gone, as wanted, and what it moved up meanwhile is found by looking again. So the run's folder is gone over
    /// until it is empty, or until a whole pass took nothing: only then is something there that can't be removed.
    private static func remove(_ name: [CChar], in runs: Int32, _ removing: Removing) -> Bool {
        var info = stat()
        guard fstatat(runs, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard info.st_mode & S_IFMT == S_IFDIR else { return removing(runs, name, 0) == 0 || errno == ENOENT }
        guard let top = entered(name, in: runs, info) else { return errno == ENOENT }
        defer { Sys.close(top) }
        var moved = 0
        while true {
            var waiting = names(in: top)
            // What went in this pass, by this sweep or by another's hand first.
            var went = 0
            while let entry = waiting.popLast() {
                guard fstatat(top, entry, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    if errno == ENOENT { went += 1 }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    if removing(top, entry, 0) == 0 || errno == ENOENT { went += 1 }
                    continue
                }
                guard let fd = entered(entry, in: top, info) else {
                    if errno == ENOENT { went += 1 }
                    continue
                }
                for child in names(in: fd) {
                    var found = stat()
                    guard fstatat(fd, child, &found, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                    guard found.st_mode & S_IFMT == S_IFDIR else {
                        if removing(fd, child, 0) == 0 || errno == ENOENT { went += 1 }
                        continue
                    }
                    // A folder moves to another only when its owner can write it (its `..` changes).
                    if found.st_mode & 0o200 == 0, let own = entered(child, in: fd, found) { Sys.close(own) }
                    // Under a number of this sweep's own. A name taken there (nothing of a run's is, in its folder
                    // itself) gets the next; a few, and the folder stays where it is.
                    for _ in 0..<8 {
                        moved += 1
                        let place = Array("moved-\(getpid())-\(moved)".utf8CString)
                        if renameat(fd, child, top, place) == 0 {
                            waiting.append(place)
                            went += 1
                            break
                        }
                        guard [EEXIST, ENOTEMPTY, ENOTDIR, EISDIR, EINVAL].contains(errno) else { break }
                    }
                }
                Sys.close(fd)
                if removing(top, entry, AT_REMOVEDIR) == 0 || errno == ENOENT { went += 1 }
            }
            if went == 0 { break }
        }
        return removing(runs, name, AT_REMOVEDIR) == 0 || errno == ENOENT
    }
}
