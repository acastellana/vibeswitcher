import Testing
@testable import VibeCore

struct RunnableCommandTests {
    @Test func shellBlocksBecomeABangCommand() {
        #expect(RunnableCommand.prompt(code: "! git -C ~/dev/site switch master && git push origin master", language: nil)
                == "! git -C ~/dev/site switch master && git push origin master")
        #expect(RunnableCommand.prompt(code: "swift test", language: "bash") == "! swift test")
        #expect(RunnableCommand.prompt(code: "$ npm install\n$ npm run dev", language: "sh") == "! npm install && npm run dev")
        // Several lines: one after the other, stopping at the first that fails; comments and blank lines left out.
        #expect(RunnableCommand.prompt(code: "# build\ncd app\n\nmake", language: "zsh") == "! cd app && make")
        // A line continued with \.
        #expect(RunnableCommand.prompt(code: "docker run \\\n  -p 80:80 nginx", language: "bash") == "! docker run -p 80:80 nginx")
        // console: the $ lines are commands, the rest is their output.
        #expect(RunnableCommand.prompt(code: "$ ls\nREADME.md\n$ pwd\n/tmp", language: "console") == "! ls && pwd")
    }

    @Test func otherBlocksAreNotRun() {
        #expect(RunnableCommand.prompt(code: "let x = 1", language: "swift") == nil)
        #expect(RunnableCommand.prompt(code: "some output", language: nil) == nil)
        #expect(RunnableCommand.prompt(code: "# just a comment", language: "bash") == nil)
        // A heredoc can't be put on one line safely.
        #expect(RunnableCommand.prompt(code: "cat <<EOF > f\nhi\nEOF", language: "bash") == nil)
    }
}
