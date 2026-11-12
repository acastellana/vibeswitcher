#if os(Linux)
// Linux has posix_spawn's standard part and a few additions, the same in glibc and in musl but for one: glibc (from
// 2.34) can tell the child to close every descriptor from a number up, musl (1.2.5) can't. And nothing replaces a
// process the way the Mac's POSIX_SPAWN_SETEXEC does: `replaceProcess` prepares this process and calls execve.
extension Platform.Spawn {
    /// Starts the program as a child of this process: its pid, or posix_spawn's error (ENOENT for a program that
    /// isn't there). Nothing is started when the spawn can't be built as asked (a descriptor below 0, say).
    ///
    /// With `keep` not nil, on a C library without the "close from" action (musl) the child closes the descriptors
    /// this process had open when the spawn began, read from /proc/self/fd: one that another thread opens after
    /// that, and doesn't mark close-on-exec, still reaches the child.
    public func start() -> Result<pid_t, Platform.Errno> {
        start(closingByListing: false)
    }

    /// `closingByListing`: close what the child doesn't keep as a C library without the "close from" action must,
    /// whatever this one has. For the tests.
    func start(closingByListing: Bool) -> Result<pid_t, Platform.Errno> {
        // The first error of a call that builds the spawn: a child is never started with less than was asked.
        var refused: Int32 = 0
        func check(_ code: Int32) {
            if refused == 0 { refused = code }
        }

        var attributes = posix_spawnattr_t()
        let initialized = posix_spawnattr_init(&attributes)
        guard initialized == 0 else { return .failure(Platform.Errno(code: initialized)) }
        defer { posix_spawnattr_destroy(&attributes) }
        var flags = POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        switch group {
        case .inherit: break
        case .ownGroup:
            flags |= POSIX_SPAWN_SETPGROUP
            // Group 0: its own, its id its pid.
            check(posix_spawnattr_setpgroup(&attributes, 0))
        case .ownSession: flags |= VIBE_POSIX_SPAWN_SETSID
        }
        check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        var toDefault = sigset_t(), none = sigset_t()
        switch defaults {
        case .all: sigfillset(&toDefault)
        case .only(let numbers):
            sigemptyset(&toDefault)
            for number in numbers { check(sigaddset(&toDefault, number) == 0 ? 0 : EINVAL) }
        }
        sigemptyset(&none)
        check(posix_spawnattr_setsigdefault(&attributes, &toDefault))
        check(posix_spawnattr_setsigmask(&attributes, &none))

        var actions = posix_spawn_file_actions_t()
        let made = posix_spawn_file_actions_init(&actions)
        guard made == 0 else { return .failure(Platform.Errno(code: made)) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for (number, stdio) in [(STDIN_FILENO, stdin), (STDOUT_FILENO, stdout), (STDERR_FILENO, stderr)] {
            switch stdio {
            // A descriptor copied onto itself: the same one, no longer close-on-exec in the child (glibc from 2.29
            // and musl from 1.1.20 read it so; the Mac has addinherit_np for it).
            case .inherit: check(posix_spawn_file_actions_adddup2(&actions, number, number))
            case .descriptor(let descriptor): check(posix_spawn_file_actions_adddup2(&actions, descriptor, number))
            case .path(let path, let flags, let mode): check(posix_spawn_file_actions_addopen(&actions, number, path, flags, mode))
            case .sameAsStdin: check(posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, number))
            }
        }
        if let directory { check(posix_spawn_file_actions_addchdir_np(&actions, directory)) }
        if let keep {
            // Kept, and no longer close-on-exec in the child; then everything else from 3 up is closed.
            let kept = Set(keep.filter { $0 > STDERR_FILENO }).sorted()
            for descriptor in kept { check(posix_spawn_file_actions_adddup2(&actions, descriptor, descriptor)) }
            if closingByListing || !Self.addCloseFromThree(&actions, keeping: kept, check) {
                switch Self.openDescriptors() {
                case .failure(let error): check(error.code)
                case .success(let open):
                    for descriptor in open where descriptor > STDERR_FILENO && !kept.contains(descriptor) {
                        check(posix_spawn_file_actions_addclose(&actions, descriptor))
                    }
                }
            }
        }

        guard refused == 0 else { return .failure(Platform.Errno(code: refused)) }
        let argv = Self.cStrings(arguments)
        defer { Self.release(argv) }
        let envp = environment.map { Self.cStrings($0) }
        defer { if let envp { Self.release(envp) } }
        var pid: pid_t = 0
        let code: Int32
        if let envp {
            code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        } else {
            code = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        }
        return code == 0 ? .success(pid) : .failure(Platform.Errno(code: code))
    }

    /// Adds to `actions`: close every descriptor from 3 up but `kept` (sorted, each above 2), whether this process
    /// has it open now or opens it before the child starts. False, and nothing added, where the C library has no
    /// "close from" action.
    private static func addCloseFromThree(_ actions: inout posix_spawn_file_actions_t, keeping kept: [Int32],
                                          _ check: (Int32) -> Void) -> Bool {
        #if canImport(Glibc)
        var next = STDERR_FILENO + 1
        for descriptor in kept {
            // Closing one that isn't open is no error.
            for between in next..<descriptor { check(posix_spawn_file_actions_addclose(&actions, between)) }
            next = descriptor + 1
        }
        check(posix_spawn_file_actions_addclosefrom_np(&actions, next))
        return true
        #else
        return false
        #endif
    }

    /// The descriptors this process has open now, sorted: /proc/self/fd's entries, without the one reading it.
    static func openDescriptors() -> Result<[Int32], Platform.Errno> {
        guard let folder = opendir("/proc/self/fd") else { return .failure(Platform.Errno(code: errno)) }
        defer { closedir(folder) }
        let own = dirfd(folder)
        var found: [Int32] = []
        while true {
            errno = 0
            guard let entry = readdir(folder) else { break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
            if let number = Int32(name), number != own { found.append(number) }
        }
        guard errno == 0 else { return .failure(Platform.Errno(code: errno)) }
        return .success(found.sorted())
    }

    /// Runs the program in place of this process, which keeps its pid: returns only when that failed, with the
    /// error and with this process as it was.
    ///
    /// Not in one step, as the Mac's is: the signals' handling and this thread's mask are reset, every descriptor
    /// the new program doesn't keep is marked close-on-exec, then execve; the other threads run meanwhile, and a
    /// descriptor one of them opens then, unmarked, reaches the new program. Only for a spawn that inherits its
    /// stdin, stdout and stderr, its directory and its group, as every caller's does: ENOTSUP for another.
    public func replaceProcess() -> Int32 {
        guard case .inherit = stdin, case .inherit = stdout, case .inherit = stderr, directory == nil,
              case .inherit = group else { return ENOTSUP }
        let marks: ExecMarks
        switch Self.markForExec(keeping: keep) {
        case .failure(let error): return error.code
        case .success(let made): marks = made
        }
        let argv = Self.cStrings(arguments)
        let envp = environment.map { Self.cStrings($0) }
        let handlers = Self.defaultSignals(defaults)
        var none = sigset_t(), mask = sigset_t()
        sigemptyset(&none)
        pthread_sigmask(SIG_SETMASK, &none, &mask)
        if let envp { execve(executable, argv, envp) } else { execve(executable, argv, environ) }
        let code = errno
        pthread_sigmask(SIG_SETMASK, &mask, nil)
        Self.restoreSignals(handlers)
        Self.undo(marks)
        Self.release(argv)
        if let envp { Self.release(envp) }
        return code == 0 ? EINVAL : code
    }

    /// What `markForExec` changed, for `undo`.
    struct ExecMarks: Equatable {
        /// Marked close-on-exec: the new program doesn't get them.
        var closing: [Int32] = []
        /// No longer marked: it does.
        var keeping: [Int32] = []
    }

    /// Marks this process's descriptors for an exec that hands on 0, 1, 2 and `keep`, each of those even when it
    /// was marked close-on-exec, and nothing else; with `keep` nil, also whatever isn't marked. EBADF, with nothing
    /// changed, when one of `keep` isn't open.
    static func markForExec(keeping keep: [Int32]?) -> Result<ExecMarks, Platform.Errno> {
        let kept = Set([STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] + (keep ?? []))
        for descriptor in keep ?? [] where fcntl(descriptor, F_GETFD) < 0 { return .failure(Platform.Errno(code: EBADF)) }
        var marks = ExecMarks()
        if keep != nil {
            let open: [Int32]
            switch openDescriptors() {
            case .failure(let error): return .failure(error)
            case .success(let listed): open = listed
            }
            for descriptor in open where !kept.contains(descriptor) {
                let flags = fcntl(descriptor, F_GETFD)
                guard flags >= 0, flags & FD_CLOEXEC == 0 else { continue }
                if fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 { marks.closing.append(descriptor) }
            }
        }
        for descriptor in kept.sorted() {
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, flags & FD_CLOEXEC != 0 else { continue }
            if fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) == 0 { marks.keeping.append(descriptor) }
        }
        return .success(marks)
    }

    /// Puts back the marks `markForExec` changed.
    static func undo(_ marks: ExecMarks) {
        for descriptor in marks.closing {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) }
        }
        for descriptor in marks.keeping {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    /// Sets the handling of `defaults`' signals to the default (an ignored signal stays ignored through an exec):
    /// each one changed with what it had, for `restoreSignals`. The ones that can't be set (SIGKILL, SIGSTOP, the C
    /// library's own) are passed over.
    static func defaultSignals(_ defaults: SignalDefaults) -> [(number: Int32, before: sigaction)] {
        let numbers: [Int32]
        switch defaults {
        // 64: Linux's highest signal, the last real-time one.
        case .all: numbers = Array(1...64)
        case .only(let given): numbers = given
        }
        // All zero: SIG_DFL, no flag, nothing blocked while it's handled.
        var standard = sigaction()
        var changed: [(number: Int32, before: sigaction)] = []
        for number in numbers {
            var before = sigaction()
            if sigaction(number, &standard, &before) == 0 { changed.append((number, before)) }
        }
        return changed
    }

    static func restoreSignals(_ changed: [(number: Int32, before: sigaction)]) {
        for (number, before) in changed {
            var before = before
            sigaction(number, &before, nil)
        }
    }
}
#endif
