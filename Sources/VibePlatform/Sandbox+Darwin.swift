#if canImport(Darwin)
// The Mac's forms of `Platform.Sandbox`: no box. Its equivalent is milestone 5's to design (the session sandbox plan's
// "The Mac"); until then nothing is confined there, and nothing changes.
extension Platform.Sandbox {
    enum System {
        static func probe() -> Facts {
            Facts(userNamespaces: false, overlay: false, landlockABI: 0, vsock: false, why: "macOS")
        }

        /// Starts nothing.
        static func enter(_ plan: Plan, doorLine: Int32?, proxyOut: Int32?, program: [String]) -> Failure {
            Failure(step: "unavailable", code: ENOTSUP)
        }
    }
}
#endif
