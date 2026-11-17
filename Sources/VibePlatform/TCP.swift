extension Platform {
    /// TCP over IPv4 and IPv6, for the session sandbox's egress proxy (the session sandbox plan's SB9): a name resolved
    /// to its addresses, a connection made to one address with a bound on the wait, and a listener on loopback (for
    /// tests, which stand a box's listener in with one). Addresses are their bytes in network order, 4 for IPv4 and
    /// 16 for IPv6: what to allow is judged above this layer (`EgressRules`), on bytes, never on a name's text.
    ///
    /// Linux's forms are in TCP+Linux.swift. The Mac has no session sandbox and so no proxy: its forms
    /// (TCP+Darwin.swift) fail with ENOTSUP and make nothing.
    public enum TCP {}
}
