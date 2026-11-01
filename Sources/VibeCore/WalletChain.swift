import Foundation

/// A chain VibeSwitcher knows by name: what the wallet card, the messages to the asking session and the browser-wallet
/// page call it, where its transactions can be seen, and its native coin. One table for all three; any other chain id
/// still goes through (the format takes any), shown as "chain <id>" with no explorer link.
public struct WalletChain: Equatable, Sendable {
    public var id: Int64
    /// The chain's name as people read it, and as the page names it to the wallet when it adds it.
    public var name: String
    /// Its EIP-3091 explorer: `<explorer>/tx/<hash>` shows a transaction. No trailing slash.
    public var explorer: String
    /// Its native coin, 18 decimals on every chain here.
    public var symbol: String
    public var decimals: Int
    /// The official public RPC the page gives the wallet when it doesn't know the chain (`wallet_addEthereumChain`); nil
    /// for a chain every wallet ships (Ethereum, Sepolia), which the page only switches to.
    public var rpc: String?

    /// Ethereum and Base, mainnets and testnets (native ETH), and GenLayer's two (GEN).
    public static let known: [Int64: WalletChain] = Dictionary(uniqueKeysWithValues: [
        WalletChain(id: 1, name: "Ethereum", explorer: "https://etherscan.io", symbol: "ETH", decimals: 18, rpc: nil),
        WalletChain(id: 11_155_111, name: "Sepolia", explorer: "https://sepolia.etherscan.io", symbol: "ETH", decimals: 18, rpc: nil),
        WalletChain(id: 8453, name: "Base", explorer: "https://basescan.org", symbol: "ETH", decimals: 18,
                    rpc: "https://mainnet.base.org"),
        WalletChain(id: 84532, name: "Base Sepolia", explorer: "https://sepolia.basescan.org", symbol: "ETH", decimals: 18,
                    rpc: "https://sepolia.base.org"),
        WalletChain(id: 42_424_242, name: "GenLayer", explorer: "https://scan.chain.genlayer.com", symbol: "GEN", decimals: 18,
                    rpc: "https://rpc.chain.genlayer.com"),
        WalletChain(id: 4221, name: "GenLayer Testnet", explorer: "https://scan.testnet-chain.genlayer.com", symbol: "GEN",
                    decimals: 18, rpc: "https://rpc.testnet-chain.genlayer.com"),
    ].map { ($0.id, $0) })

    /// The chain `id` names, or nil for one VibeSwitcher doesn't know.
    public static func named(_ id: Int64) -> WalletChain? { known[id] }

    /// "Base", or "chain 5" for one without a name.
    public static func name(_ id: Int64) -> String { known[id]?.name ?? "chain \(id)" }
}
