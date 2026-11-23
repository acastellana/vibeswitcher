import Foundation
import VibeCore

/// The node's own folders for its external plugins, under `<root>/plugins` and `<root>/plugin-requests` (the review of
/// step C, L4): never followed through a link, never another's. A folder that is a link, not a folder, or not the
/// user's is refused, and nothing in it is changed or removed.
enum PluginFolders {
    /// Why `url` isn't a folder the node may use as its own (nil: it may, or it isn't there yet): a link, not a folder,
    /// another user's.
    static func refusal(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK { return "\(url.path) is a link, not the node's own folder" }
        if info.st_mode & S_IFMT != S_IFDIR { return "\(url.path) isn't a folder" }
        if info.st_uid != getuid() { return "\(url.path) isn't yours" }
        return nil
    }

    /// `url` under `root`, with `root` resolved once (the node's root may itself be reached through a link: the
    /// review of bd001923, N6) and every folder below it checked (`refusal`): the path to use, or why not.
    static func checked(_ url: URL, root: URL) -> Result<URL, PluginRefusal> {
        let given = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard path.hasPrefix(given + "/") else { return .failure(PluginRefusal("\(path) isn't under the node's root")) }
        guard let real = realpath(given, nil) else { return .failure(PluginRefusal("the node's root \(given) isn't there")) }
        var walked = URL(fileURLWithPath: String(cString: real))
        free(real)
        for part in path.dropFirst(given.count + 1).split(separator: "/") {
            walked.appendPathComponent(String(part))
            if let why = refusal(walked) { return .failure(PluginRefusal(why)) }
        }
        return .success(walked)
    }

    /// `url` (under `root`) made, private to you, each folder below the resolved root checked first; or why not.
    static func own(_ url: URL, root: URL) -> Result<URL, PluginRefusal> {
        let target: URL
        switch checked(url, root: root) {
        case .failure(let why): return .failure(why)
        case .success(let resolved): target = resolved
        }
        do { try VibePaths.ensurePrivate(target) } catch { return .failure(PluginRefusal("\(target.path) couldn't be made: \(error)")) }
        // Made or not by us: checked again now that it is there.
        if let why = refusal(target) { return .failure(PluginRefusal(why)) }
        return .success(target)
    }

    /// Everything in the node's own folder `url` removed, links themselves never followed; with `andItself`, the folder
    /// too. Nothing when it isn't the node's own (`refusal`). Returns why not, or nil.
    @discardableResult
    static func empty(_ url: URL, root: URL, andItself: Bool = false) -> String? {
        switch checked(url, root: root) {
        case .failure(let why): return why.description
        case .success(let resolved): return emptied(resolved, andItself: andItself)
        }
    }

    /// `url`, checked already, emptied: links never followed.
    @discardableResult
    private static func emptied(_ url: URL, andItself: Bool) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if let why = refusal(url) { return why }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            let entry = url.appendingPathComponent(name)
            var item = stat()
            guard lstat(entry.path, &item) == 0 else { continue }
            if item.st_mode & S_IFMT == S_IFDIR { emptied(entry, andItself: true) } else { unlink(entry.path) }
        }
        if andItself { rmdir(url.path) }
        return nil
    }
}

/// What an external plugin's program loads before its own code, checked at `plugin add` and at every start (the review
/// of step C, H1): the SHA-256 covers the program, so everything else it loads must be root's and beyond anyone else's
/// reach. An ELF program's interpreter, its RUNPATH and RPATH entries and any library it names by a path: each an
/// absolute path whose every folder and file is root's and not writable by a group or others, never `$ORIGIN`. A
/// script's `#!` interpreter: the same, and never `env` (which would look the interpreter up on PATH). Anything else
/// isn't run.
enum PluginProgram {
    /// Why the program in `bytes` isn't run (nil: it may be).
    static func refusal(_ bytes: Data) -> String? {
        if bytes.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return elfRefusal(bytes) }
        guard bytes.starts(with: Array("#!".utf8)) else { return "its program is neither an ELF program nor a #! script" }
        return shebangRefusal(bytes)
    }

    /// The interpreters a script plugin may name, by their absolute paths (each must also be root's: `trusted`).
    static let interpreters: Set<String> = ["/bin/sh", "/usr/bin/sh", "/bin/bash", "/usr/bin/bash", "/bin/dash", "/usr/bin/dash", "/usr/bin/python3"]

    /// The `#!` line as the kernel reads it (the automated review of bd001923): the first 256 bytes at most, the
    /// interpreter up to the first space, everything after it ONE argument; the program then runs as
    /// `interpreter [that argument] /proc/self/fd/N`. Checked stricter than the kernel: the line ends with a newline within
    /// its first 255 bytes; no tab, carriage return, double or trailing space; the interpreter one of `interpreters` (or
    /// /usr/bin/python3.N), root's all the way; at most one argument, exactly one of the tokens this node lists for it.
    static func shebangRefusal(_ bytes: Data) -> String? {
        let head = [UInt8](bytes.prefix(256))
        guard let newline = head.firstIndex(of: UInt8(ascii: "\n")), newline < 255 else {
            return "its #! line doesn't end within its first 255 bytes (the kernel reads 256)"
        }
        let line = Array(head[2..<newline])
        guard !line.contains(UInt8(ascii: "\t")), !line.contains(UInt8(ascii: "\r")), line.last != UInt8(ascii: " "),
              line.first == UInt8(ascii: "/"), !String(decoding: line, as: UTF8.self).contains("  ") else {
            return "its #! line is the interpreter's path and at most one flag, with single spaces: no tab, carriage return or trailing space"
        }
        let words = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 1).map(String.init)
        let interpreter = words[0]
        let name = (interpreter as NSString).lastPathComponent
        guard interpreters.contains(interpreter) || isPython3N(interpreter) else {
            return "its #! interpreter \(ConfigSeal.inert(interpreter, limit: 120)) isn't one this node runs (\(interpreters.sorted().joined(separator: ", ")), /usr/bin/python3.N)"
        }
        if let why = trusted(interpreter) { return "its #! interpreter: \(why)" }
        guard words.count == 2 else { return nil }
        let argument = words[1]
        guard interpreterTokens(name).contains(argument) else {
            let allowed = interpreterTokens(name)
            return "its #! line passes \(ConfigSeal.inert(argument, limit: 80)) to \(name): " + (allowed.isEmpty ? "it takes no argument" : "only one of \(allowed.sorted().joined(separator: " ")) may follow it, as one token")
        }
        return nil
    }

    static func isPython3N(_ path: String) -> Bool {
        guard path.hasPrefix("/usr/bin/python3.") else { return false }
        let minor = path.dropFirst("/usr/bin/python3.".count)
        return !minor.isEmpty && minor.count <= 3 && minor.allSatisfy(\.isNumber)
    }

    /// The one argument a `#!` line may pass to an interpreter, as a single token: python3's `-I` (isolated) alone or
    /// followed by any of S, s, B, u, E, each at most once; none to a shell.
    static func interpreterTokens(_ name: String) -> Set<String> {
        guard name == "python3" || name.hasPrefix("python3.") else { return [] }
        var tokens: Set<String> = ["-I"]
        let letters = Array("SsBuE")
        func extend(_ prefix: String, _ left: [Character]) {
            for (index, letter) in left.enumerated() {
                let token = prefix + String(letter)
                tokens.insert(token)
                var rest = left
                rest.remove(at: index)
                extend(token, rest)
            }
        }
        extend("-I", letters)
        return tokens
    }

    /// The most a program's file may hold (the review of bd001923, N4); its manifest's is `PluginManifest.bytesAtMost`.
    static let programBytesAtMost = 64 << 20

    /// The program at `path` read into a sealed copy, within `programBytesAtMost`, of the size recorded at its add when
    /// `expected` names one (compared before the copy is made, and again after); or why not.
    static func sealed(_ path: String, expected: Int?, name: String) -> Result<Platform.ProcessSelf.SealedCopy, PluginRefusal> {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return .failure(PluginRefusal("its program couldn't be opened (errno \(errno))")) }
        defer { Sys.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return .failure(PluginRefusal("its program isn't a regular file")) }
        let size = Int(info.st_size)
        guard size <= programBytesAtMost else { return .failure(PluginRefusal("its program is over \(programBytesAtMost >> 20) MiB")) }
        if let expected, size != expected {
            return .failure(PluginRefusal("its program changed since you added it (its size): `vibeswitcher plugin add` it again"))
        }
        switch Platform.ProcessSelf.sealedCopy(of: fd, name: name) {
        case .failure(let error): return .failure(PluginRefusal("its program couldn't be read (errno \(error.code))"))
        case .success(let copy):
            guard copy.size == size else {
                Sys.close(copy.fd)
                return .failure(PluginRefusal("its program changed while it was read"))
            }
            return .success(copy)
        }
    }

    /// Why `path` isn't root's all the way (nil: it is): absolute, no `$ORIGIN`, every folder and the file itself (and
    /// what a link in it resolves to) owned by root and not writable by a group or others.
    static func trusted(_ path: String) -> String? {
        let shown = ConfigSeal.inert(path, limit: 200)
        guard path.hasPrefix("/"), !path.contains("$") else { return "\(shown) isn't an absolute path" }
        guard let real = realpath(path, nil) else { return "\(shown) isn't there" }
        let resolved = String(cString: real)
        free(real)
        for candidate in [path, resolved] {
            var walked = ""
            for part in [""] + candidate.split(separator: "/").map(String.init) {
                walked = part.isEmpty ? "/" : (walked == "/" ? "/" + part : walked + "/" + part)
                var info = stat()
                guard lstat(walked, &info) == 0 else { return "\(shown) isn't there" }
                let link = info.st_mode & S_IFMT == S_IFLNK
                guard info.st_uid == 0, link || info.st_mode & 0o022 == 0 else {
                    return "\(ConfigSeal.inert(walked, limit: 200)) isn't root's alone (anyone else could change what runs)"
                }
            }
        }
        return nil
    }

    /// The most of an ELF program the check reads: its headers, loader path, dynamic section and strings must lie in
    /// its first 64 MiB, or it is refused (a program is read whole into its sealed copy; only this much is parsed).
    static let elfBytesRead = 64 << 20
    static let programHeadersAtMost = 256
    static let dynamicEntriesAtMost = 4096
    static let stringBytesAtMost = 4096
    /// The most distinct paths (libraries by path, search folders) one program's check walks: each is a walk of the file
    /// system, and a dynamic section of 4,096 search paths of 2,048 folders each asked 8 million of them (19 s, the fuzz
    /// tests of 2026-11-23). A program past it isn't run.
    static let pathsCheckedAtMost = 64

    /// An ELF program's loader, search paths and named libraries, each `trusted`; 64-bit little-endian only. Every field
    /// is untrusted: read as UInt64, checked against the bytes read before any conversion, never added or multiplied
    /// unchecked; anything out of range refuses the program (the automated review of bd001923: never a trap).
    static func elfRefusal(_ bytes: Data) -> String? {
        let data = [UInt8](bytes.prefix(elfBytesRead))
        let count = UInt64(data.count)
        let unread = "its ELF headers don't read (out of range or past what is read of it, \(elfBytesRead >> 20) MiB)"
        /// `at` + `width` within the bytes read: the start as an Int, or nil.
        func within(_ at: UInt64, _ width: UInt64) -> Int? {
            let (end, over) = at.addingReportingOverflow(width)
            guard !over, end <= count else { return nil }
            return Int(exactly: at)
        }
        func field(_ at: UInt64, _ width: Int) -> UInt64? {
            guard let start = within(at, UInt64(width)) else { return nil }
            return (0..<width).reduce(UInt64(0)) { $0 | UInt64(data[start + $1]) << (8 * UInt64($1)) }
        }
        func string(_ at: UInt64) -> String? {
            guard let start = within(at, 1) else { return nil }
            let end = min(data.count, start + stringBytesAtMost)
            guard let nul = data[start..<end].firstIndex(of: 0) else { return nil }
            return String(decoding: data[start..<nul], as: UTF8.self)
        }
        guard data.count >= 64, data[4] == 2, data[5] == 1 else { return "its program is an ELF this node doesn't read (only 64-bit little-endian)" }
        guard let phoff = field(0x20, 8), let size = field(0x36, 2), let number = field(0x38, 2) else { return unread }
        guard size >= 56, number <= UInt64(programHeadersAtMost) else { return "its ELF program headers are more or other than this node reads" }
        var loads: [(vaddr: UInt64, offset: UInt64, size: UInt64)] = []
        var dynamic: (offset: UInt64, size: UInt64)?
        for index in 0..<number {
            let (step, over1) = index.multipliedReportingOverflow(by: size)
            let (at, over2) = phoff.addingReportingOverflow(step)
            guard !over1, !over2, within(at, 56) != nil, let type = field(at, 4), let offset = field(at + 8, 8), let vaddr = field(at + 16, 8),
                  let filesz = field(at + 32, 8) else { return unread }
            switch type {
            case 1: loads.append((vaddr, offset, filesz))
            case 2:
                guard dynamic == nil else { return "its ELF program has two dynamic sections" }
                dynamic = (offset, filesz)
            case 3:
                guard within(offset, filesz) != nil, let interpreter = string(offset) else { return "its ELF interpreter doesn't read" }
                if let why = trusted(interpreter) { return "its ELF interpreter: \(why)" }
            default: break
            }
        }
        guard let dynamic else { return nil }
        guard within(dynamic.offset, dynamic.size) != nil else { return unread }
        var entries: [(tag: UInt64, value: UInt64)] = []
        var at = dynamic.offset
        let end = dynamic.offset + dynamic.size
        while at + 16 <= end {
            guard entries.count < dynamicEntriesAtMost else { return "its ELF dynamic section has over \(dynamicEntriesAtMost) entries" }
            guard let tag = field(at, 8), let value = field(at + 8, 8) else { return unread }
            if tag == 0 { break }
            entries.append((tag, value))
            at += 16
        }
        // Tags ld.so also loads files by (audit libraries, filters, a config file): not followed here, so refused.
        let unfollowed: [UInt64: String] = [0x6ffffefc: "DT_AUDIT", 0x6ffffefb: "DT_DEPAUDIT", 0x7fffffff: "DT_FILTER",
                                            0x7ffffffd: "DT_AUXILIARY", 0x6ffffefa: "DT_CONFIG"]
        if let tag = entries.first(where: { unfollowed[$0.tag] != nil }) {
            return "its ELF program names a library the check doesn't follow (\(unfollowed[tag.tag]!))"
        }
        // A library by a bare name (DT_NEEDED without a slash) is found through the search paths checked here and the
        // system's default ones (root's: ld.so.cache, /lib, /usr/lib): the program's environment has no LD_LIBRARY_PATH.
        let named = entries.filter { [1, 15, 29].contains($0.tag) }
        guard !named.isEmpty else { return nil }
        // The string table is an address: the loaded segment holding it gives its place in the file.
        guard let table = entries.first(where: { $0.tag == 5 })?.value,
              let load = loads.first(where: { table >= $0.vaddr && table - $0.vaddr < $0.size }) else {
            return "its ELF string table doesn't read"
        }
        let (base, over) = (table - load.vaddr).addingReportingOverflow(load.offset)
        guard !over, within(base, 1) != nil else { return "its ELF string table doesn't read" }
        // Each distinct path walked once, and only so many of them.
        var checked: Set<String> = []
        func trustedOnce(_ path: String) -> String? {
            if checked.contains(path) { return nil }
            guard checked.count < pathsCheckedAtMost else { return "it names over \(pathsCheckedAtMost) libraries and search folders by path" }
            checked.insert(path)
            return trusted(path)
        }
        for entry in named {
            let (place, over) = base.addingReportingOverflow(entry.value)
            guard !over, let text = string(place) else { return "its ELF dynamic section doesn't read" }
            if entry.tag == 1 {
                // A library by name is found in root's folders; by a path, that path must be root's.
                if text.contains("/"), let why = trustedOnce(text) { return "a library it names: \(why)" }
                continue
            }
            if text.contains("$ORIGIN") || text.contains("${ORIGIN}") { return "its ELF search path names $ORIGIN (its own folder)" }
            for folder in text.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                guard !folder.isEmpty else { return "its ELF search path has an empty entry (the working folder)" }
                if let why = trustedOnce(folder) { return "its ELF search path: \(why)" }
            }
        }
        return nil
    }
}
