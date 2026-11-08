import Foundation

/// The product inventory (`docs/process/product-inventory.md`): what the project already does for the user, generated
/// from its code by its own `scripts/product-inventory.sh` (VibeSwitcher's lists menus, Settings, the chat's and the
/// terminal's features). The lead reads it before it proposes a feature (`LeadPrompts.productCheck`), so it has to
/// follow the code: the lead's records commit after a merge (`LeadRecords`) makes it again when what it's made from
/// changed, and commits it with them.
///
/// Made from a commit, never from the main checkout's files (the user's uncommitted work isn't the product): the
/// script and the inputs it names (its `# inputs:` line) are taken out of the commit into a scratch folder and the
/// script runs there, as branch code (`BranchCode`), with a time limit. Anything that goes wrong (no script, a
/// failure, a timeout, empty output) gives nil, and the records are committed without it: the inventory never fails a
/// merge or a records commit.
public enum ProductInventory {
    public static let script = "scripts/product-inventory.sh"
    public static let output = "docs/process/product-inventory.md"
    /// The longest a run may take (it takes seconds).
    static let timeout: TimeInterval = 60

    /// The paths the script at `commit` says it reads (`# inputs: A B`), relative to the repository; nil when `commit`
    /// has no script or the line is missing or names a path outside the repository.
    static func inputs(root: String, commit: String) -> [String]? {
        let text = Git.run(["cat-file", "-p", "\(commit):\(script)"], in: root)
        guard text.ok else { return nil }
        guard let line = text.output.split(separator: "\n").first(where: { $0.hasPrefix("# inputs:") }) else { return nil }
        let paths = line.dropFirst("# inputs:".count).split(separator: " ").map(String.init)
        guard !paths.isEmpty, paths.allSatisfy({ !$0.hasPrefix("/") && !$0.hasPrefix("-") && !$0.split(separator: "/").contains("..") })
        else { return nil }
        return paths
    }

    /// What the inventory at `commit` is made from, as git names it: the script's blob and each input's tree. The same
    /// key, the same inventory (the script is deterministic); nil when `commit` has no script.
    static func key(root: String, commit: String) -> String? {
        guard let inputs = inputs(root: root, commit: commit) else { return nil }
        let ids = ([script] + inputs).map { path in
            Git.run(["rev-parse", "--verify", "--quiet", "\(commit):\(path)"], in: root).output
        }
        guard !ids[0].isEmpty else { return nil }
        return ids.joined(separator: " ")
    }

    /// The inventory as `commit`'s script makes it from `commit`'s inputs, or nil (see the type).
    static func generate(root: String, commit: String, timeout: TimeInterval = timeout) -> Data? {
        guard let inputs = inputs(root: root, commit: commit) else { return nil }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("vibeswitcher-inventory-\(UUID().uuidString)").path
        defer { try? fm.removeItem(atPath: scratch) }
        let tree = scratch + "/tree", tar = scratch + "/inputs.tar", tmp = scratch + "/tmp"
        do {
            try fm.createDirectory(atPath: tree, withIntermediateDirectories: true)
            try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        } catch { return nil }
        guard Git.run(["archive", "--format=tar", "-o", tar, commit, "--", script] + inputs, in: root).ok,
              Shell.run(executable: "/usr/bin/tar", args: ["-xf", tar, "-C", tree], in: scratch, timeout: timeout).ok else { return nil }
        let run = Shell.run(executable: "/bin/bash", args: [tree + "/" + script, "--root", tree, "--write"], in: tree,
                            env: ["TMPDIR": tmp + "/"], timeout: timeout, branchCode: true)
        guard run.ok, !run.timedOut, let made = fm.contents(atPath: tree + "/" + output), !made.isEmpty else { return nil }
        return made
    }
}
