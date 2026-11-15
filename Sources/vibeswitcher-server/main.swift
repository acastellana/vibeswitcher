// The node's server: the session host's server child (the engine plan's E1; the security architecture document's S2
// and S3). The host starts it from a sealed copy of its `--server` file, non-dumpable from its exec, with the app's
// connector; it serves the command line on `<root>/v2/server.sock` and reaches the host only through the connector.
import Foundation
import VibeCore
import VibeNode

// Its first statements, in order, are canonical (stage 2's S2-D1 and the bootstrap path cite this list): the image it
// was started from closed; hardened (non-dumpable from its exec already; kept for a build run from a readable file);
// a traced server exits 75 writing nothing (the host logs the exit); the connector, which arrives kept and so
// inheritable, marked close-on-exec; then SIGPIPE settled. None of them writes.
Platform.ProcessSelf.closeInheritedImage()
_ = Platform.ProcessSelf.harden()
if ServerStart.isTraced { _exit(75) }
ServerStart.markConnector(CommandLine.arguments)
signal(SIGPIPE, SIG_IGN)
ServerStart.run(CommandLine.arguments)
