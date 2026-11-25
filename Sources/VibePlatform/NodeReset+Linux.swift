#if os(Linux)
// Linux's forms of `Platform.NodeReset`: nothing (no checked Mac node runs on Linux).
extension Platform.NodeReset {
    enum System {
        static func processState(keeping: Set<Int32>) -> String? { nil }
        static var userTemporaryFolder: String? { nil }
    }
}
#endif
