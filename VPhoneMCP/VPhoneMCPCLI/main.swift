import Darwin
import Foundation

// vphone-mcp: an MCP server over VM sockets. It reads JSON-RPC lines on stdin and
// answers on stdout. Exit codes: 0 at end of input, 1 when stdin or stdout fails,
// 2 for a usage error.

// A closed pipe is an error value from write, not a signal that kills the process.
signal(SIGPIPE, SIG_IGN)

func usageFailure(_ problem: String) -> Never {
    fputs(usageText(problem), stderr)
    exit(2)
}

var profileArg: Profile?
var toolsArg: Set<String>?
var rest = CommandLine.arguments.dropFirst().makeIterator()
while let flag = rest.next() {
    guard ["--profile", "--tools"].contains(flag) else { usageFailure("unknown option \(flag)") }
    guard let value = rest.next() else { usageFailure("\(flag) needs a value") }
    switch flag {
    case "--profile":
        guard profileArg == nil else { usageFailure("--profile given twice") }
        guard let profile = Profile(rawValue: value) else {
            usageFailure("--profile \(value) is not one of full, standard, readonly")
        }
        profileArg = profile
    default:
        guard toolsArg == nil else { usageFailure("--tools given twice") }
        let entries = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !entries.contains("") else { usageFailure("--tools entry is empty") }
        var seen = Set<String>()
        for name in entries {
            guard toolNames.contains(name) else { usageFailure("--tools entry \(name) is not one of the tool names") }
            guard seen.insert(name).inserted else { usageFailure("--tools entry \(name) is repeated") }
        }
        toolsArg = seen
    }
}

let server: MCPServer
do {
    server = try MCPServer(profile: profileArg ?? .full, allowed: toolsArg ?? Set(toolNames))
} catch let error as StartupError {
    usageFailure(error.problem)
} catch {
    usageFailure("\(error)")
}
if let failure = readLines(fd: STDIN_FILENO, handle: { server.handle(line: $0) }, write: writeStdout) {
    fputs("vphone-mcp: \(failure)\n", stderr)
    exit(1)
}
exit(0)
