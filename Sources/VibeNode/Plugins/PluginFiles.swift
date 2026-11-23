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

    /// `url` (under `root`) made, private to you, each folder from `root` down checked first (`refusal`); or why not.
    static func own(_ url: URL, root: URL) -> Result<URL, PluginRefusal> {
        let top = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard path.hasPrefix(top + "/") else { return .failure(PluginRefusal("\(path) isn't under the node's root")) }
        var walked = URL(fileURLWithPath: top)
        if let why = refusal(walked) { return .failure(PluginRefusal(why)) }
        for part in path.dropFirst(top.count + 1).split(separator: "/") {
            walked.appendPathComponent(String(part))
            if let why = refusal(walked) { return .failure(PluginRefusal(why)) }
        }
        do { try VibePaths.ensurePrivate(url) } catch { return .failure(PluginRefusal("\(path) couldn't be made: \(error)")) }
        // Made or not by us: checked again now that it is there.
        if let why = refusal(url) { return .failure(PluginRefusal(why)) }
        return .success(url)
    }

    /// Everything in the node's own folder `url` removed, links themselves never followed; with `andItself`, the folder
    /// too. Nothing when it isn't the node's own (`refusal`). Returns why not, or nil.
    @discardableResult
    static func empty(_ url: URL, andItself: Bool = false) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if let why = refusal(url) { return why }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] {
            let entry = url.appendingPathComponent(name)
            var item = stat()
            guard lstat(entry.path, &item) == 0 else { continue }
            if item.st_mode & S_IFMT == S_IFDIR { empty(entry, andItself: true) } else { unlink(entry.path) }
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
        let first = bytes.prefix(256).split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first ?? Data()
        let line = String(decoding: first.dropFirst(2), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let interpreter = line.split(separator: " ").first.map(String.init), !interpreter.isEmpty else {
            return "its #! line names no interpreter"
        }
        if (interpreter as NSString).lastPathComponent == "env" { return "its #! interpreter is env, which looks it up on PATH: name it by its path" }
        return trusted(interpreter).map { "its #! interpreter: \($0)" }
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
        let named = entries.filter { [1, 15, 29].contains($0.tag) }
        guard !named.isEmpty else { return nil }
        // The string table is an address: the loaded segment holding it gives its place in the file.
        guard let table = entries.first(where: { $0.tag == 5 })?.value,
              let load = loads.first(where: { table >= $0.vaddr && table - $0.vaddr < $0.size }) else {
            return "its ELF string table doesn't read"
        }
        let (base, over) = (table - load.vaddr).addingReportingOverflow(load.offset)
        guard !over, within(base, 1) != nil else { return "its ELF string table doesn't read" }
        for entry in named {
            let (place, over) = base.addingReportingOverflow(entry.value)
            guard !over, let text = string(place) else { return "its ELF dynamic section doesn't read" }
            if entry.tag == 1 {
                // A library by name is found in root's folders; by a path, that path must be root's.
                if text.contains("/"), let why = trusted(text) { return "a library it names: \(why)" }
                continue
            }
            if text.contains("$ORIGIN") || text.contains("${ORIGIN}") { return "its ELF search path names $ORIGIN (its own folder)" }
            for folder in text.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                guard !folder.isEmpty else { return "its ELF search path has an empty entry (the working folder)" }
                if let why = trusted(folder) { return "its ELF search path: \(why)" }
            }
        }
        return nil
    }
}
