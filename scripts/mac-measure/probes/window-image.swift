// K-M16's here part (pair-token.c, part three, (w2)): a hardened Swift image linking Foundation, as the node's host
// does, whose first statement takes the time (mach_absolute_time), so the probe can say how long the window before any
// statement of the image's own is (dyld and the libraries' initializers); its first statement after that writes the
// marker on descriptor 99 unbuffered, as pair-image's does. It writes one line on descriptor 3 and ends;
// it reads nothing else and touches no other process.
import Foundation

let firstStatement = mach_absolute_time()
_ = "  main's first statement reached (an unbuffered write on descriptor 99)\n".withCString { write(99, $0, strlen($0)) }
let line = "  first statement at \(firstStatement) (mach_absolute_time); Foundation linked: \(NSString(string: "yes"))\n"
FileHandle(fileDescriptor: 3, closeOnDealloc: true).write(line.data(using: .utf8)!)
