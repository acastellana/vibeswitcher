import Foundation

extension Platform {
    /// The words a message to the user has for the machine and its terminal: the Mac's names ("this Mac", its
    /// Terminal app), and plain ones on Linux, which has neither.
    public enum Words {
        /// The machine VibeSwitcher runs on: "this Mac"; Linux: "this computer".
        public static var thisMachine: String {
            #if canImport(Darwin)
            return "this Mac"
            #else
            return "this computer"
            #endif
        }

        /// Where a command is run by hand: "in Terminal" (the Mac's app); Linux: "in a terminal".
        public static var inATerminal: String {
            #if canImport(Darwin)
            return "in Terminal"
            #else
            return "in a terminal"
            #endif
        }

        /// A fresh shell to try a command in: "a new Terminal window"; Linux: "a new terminal window".
        public static var aNewTerminalWindow: String {
            #if canImport(Darwin)
            return "a new Terminal window"
            #else
            return "a new terminal window"
            #endif
        }

        /// How to get git when there's none: "Run xcode-select --install in Terminal" (Apple's Command Line Tools have
        /// it); Linux: "Install git with your system's package manager".
        public static var installGit: String {
            #if canImport(Darwin)
            return "Run xcode-select --install in Terminal"
            #else
            return "Install git with your system's package manager"
            #endif
        }
    }
}
