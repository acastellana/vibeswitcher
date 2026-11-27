import Foundation
#if canImport(Glibc)
import Glibc
#endif
import VibeKeep

// The root-owned keeper (docs/superpowers/specs/2026-11-27-v2-mac-keeper-design.md): only its target in this slice
// (K0). Its program (the serial loop, `open` and `swap`, its one argument) is slice K3; until then it does nothing and
// says so.
signal(SIGPIPE, SIG_IGN)
_ = Keep.self
_ = "vibeswitcher-keeper: not built yet (the keeper design's slice K3); nothing done\n".withCString { write(2, $0, strlen($0)) }
exit(69)
