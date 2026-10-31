import SwiftUI
import VibeCore

/// A Passage peer that could be the Wallet Manager's Mac, as the caller lists them.
struct WalletPeerChoice: Equatable, Hashable, Identifiable {
    var peerID: String
    var name: String
    var id: String { peerID }
}

/// Settings › Wallet: which Passage peer is the Wallet Manager's Mac, and which `passage` carries requests there. Until a peer is
/// chosen, wallet requests are refused.
/// Settings › Wallet's peers, read from `passage peers --no-discovery --json` off the main thread: again each time the
/// tab shows and when the passage path changes; the latest read wins (one for a path typed since is dropped).
final class WalletPeerList: ObservableObject {
    @Published private(set) var peers: [WalletPeerChoice] = []
    /// The peers for the passage path setting (empty: `passage` on the PATH), or nil when passage couldn't list them.
    let load: (_ passagePath: String) -> [WalletPeerChoice]?
    private var generation = 0

    init(load: @escaping (_ passagePath: String) -> [WalletPeerChoice]? = { path in
        (path.isEmpty ? WalletPeerChoice.findPassage() : path).flatMap { WalletPeerChoice.list(passage: $0) }
    }) {
        self.load = load
    }

    /// Reads them again; `then` runs on the main thread once this read's peers are shown (not for one a later read
    /// replaced).
    func reload(passagePath: String, then: @escaping () -> Void = {}) {
        generation += 1
        let mine = generation
        let load = self.load
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let peers = load(passagePath) ?? []
            DispatchQueue.main.async {
                guard let self, self.generation == mine else { return }
                if self.peers != peers { self.peers = peers }
                then()
            }
        }
    }
}

struct WalletSettingsTab: View {
    @ObservedObject var preferences: Preferences
    /// The peers to choose from, read from Passage.
    @ObservedObject var peerList: WalletPeerList
    var peers: [WalletPeerChoice] { peerList.peers }

    static let refusedNote = "Wallet requests are refused until a Wallet Manager peer is chosen."

    /// The picker's rows: the peers given, and the saved one still, when it isn't among them (so a peer that's away
    /// isn't dropped from your settings by opening them).
    static func choices(_ peers: [WalletPeerChoice], saved: String) -> [WalletPeerChoice] {
        guard !saved.isEmpty, !peers.contains(where: { $0.peerID == saved }) else { return peers }
        return peers + [WalletPeerChoice(peerID: saved, name: "Not found now (\(saved))")]
    }

    /// The line under the picker: refused until a peer is chosen, else where requests go.
    static func status(_ peers: [WalletPeerChoice], saved: String) -> String {
        guard !saved.isEmpty else { return refusedNote }
        let name = peers.first { $0.peerID == saved }?.name ?? saved
        return "Requests go to \(name) once you press Send to Wallet Manager on their card. Nothing is sent before that."
    }

    var body: some View {
        Form {
            Section {
                Picker("Wallet Manager peer", selection: $preferences.walletPeerID) {
                    Text("None").tag("")
                    ForEach(Self.choices(peers, saved: preferences.walletPeerID)) { peer in
                        Text(peer.name).tag(peer.peerID)
                    }
                }
                Text(Self.status(peers, saved: preferences.walletPeerID))
                    .font(.callout)
                    .foregroundStyle(preferences.walletPeerID.isEmpty ? SessionStatus.needsInput.color : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if peers.isEmpty {
                    Text("No Passage peers found. Pair the Wallet Manager's Mac in Passage first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Wallet Manager's Mac")
            } footer: {
                SettingsFooter("An agent asks for a transaction with vs-wallet request (on every session's PATH; vs-wallet help says how), "
                    + "and the request shows as a card in its chat. Only when you press Send to Wallet Manager does it go "
                    + "through Passage to the Wallet Manager on its Mac, which checks it; you sign there on the hardware wallet. "
                    + "VibeSwitcher never signs. The Wallet Manager's answers go back to the agent as messages.")
            }
            Section {
                LabeledContent("Command path") {
                    TextField("Passage path", text: $preferences.walletPassagePath, prompt: Text("passage"))
                        .labelsHidden().accessibilityLabel("Path to the passage command")
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Passage")
            } footer: {
                SettingsFooter("The passage command requests go through. Empty: passage on your PATH.")
            }
        }
        .formStyle(.grouped)
        .onAppear { peerList.reload(passagePath: preferences.walletPassagePath) }
        .onChange(of: preferences.walletPassagePath) { _, path in peerList.reload(passagePath: path) }
    }
}

extension WalletPeerChoice {
    /// `passage` on the login shell's PATH (a shell runs: off the main thread), or nil.
    static func findPassage() -> String? {
        if case .found(let path) = LoginShellCommand.resolve("passage") { return path }
        return nil
    }

    /// The paired peers, as `passage peers --no-discovery --json` lists them (no browsing, no Local Network use): one JSON
    /// object per line with `peerID` and `name`. Blocks: call it off the main thread. Nil when passage failed.
    static func list(passage: String, timeout: TimeInterval = 15) -> [WalletPeerChoice]? {
        guard passage.hasPrefix("/") else { return nil }
        let run = Shell.run(executable: passage, args: ["peers", "--no-discovery", "--json"], in: "/", timeout: timeout, ownSession: true)
        guard run.ok, !run.signaled else { return nil }
        return parse(run.output)
    }

    /// Each line's `peerID` (8 lower-case hex digits, else the line is skipped) and `name` (control characters
    /// dropped; "(unnamed)" when empty).
    static func parse(_ output: String) -> [WalletPeerChoice] {
        output.split(separator: "\n").compactMap { line in
            guard case let .object(members)? = try? WalletRequestFormat.Value.parse(Data(line.utf8)) else { return nil }
            func text(_ key: String) -> String? {
                guard case let .string(value)? = members.first(where: { $0.key == key })?.value else { return nil }
                return value
            }
            guard let id = text("peerID"), PassageLink(executable: "/", walletPeer: id) != nil else { return nil }
            let name = String((text("name") ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100).map(Character.init))
            return WalletPeerChoice(peerID: id, name: name.isEmpty ? "(unnamed)" : "\(name) (\(id))")
        }
    }
}
