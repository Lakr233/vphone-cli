import Darwin
import Foundation

// vphone-launchpad-cli: drives a running vphone-launchpad over its control
// socket. It holds no state and no privileges of its own: the app installs
// bundles through its helper, runs each machine's own bundle, and shows
// every command in its window. Output lines go to stderr as they arrive; the
// result, a JSON document, goes to stdout. The exit status is 0 on success.

// MARK: - Arguments

func usage() -> String {
    var text = """
    usage: vphone-launchpad-cli [--foreground] <command> [arguments] [options]

    Drives a running vphone-launchpad, starting it if needed. Progress goes to
    stderr; the result is JSON on stdout.

    A Launchpad started by this tool starts hidden and leaves the frontmost
    app alone; its window comes back from the Dock or the menu bar.
    --foreground opens it with its window in front instead.

    Each machine runs with the Core Bundle it is bound to. The default bundle
    is only what vm create binds by default and what exec and library-wide
    commands run with.

    """
    for command in VPhoneLaunchpadControlCommand.all {
        text += "\n  \(command.usage)\n      \(command.summary)\n"
    }
    return text
}

func fail(_ message: String, detail: String? = nil) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    if let detail, !detail.isEmpty {
        FileHandle.standardError.write(Data("\(detail)\n".utf8))
    }
    exit(1)
}

// MARK: - Connection

func connectControl() -> Int32? {
    var address = sockaddr_un()
    guard VPhoneLaunchpadControl.address(VPhoneLaunchpadControl.socketPath, into: &address) else {
        fail("the control socket path is too long: \(VPhoneLaunchpadControl.socketPath)")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return nil
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }
    _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    return fd
}

/// Opens the Launchpad this tool ships in, else the one Launch Services knows,
/// and waits for its socket. By default it starts hidden and does not become
/// the active app: its window is still created, and the window's task is what
/// opens the socket.
func launchAndConnect(foreground: Bool) -> Int32 {
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let app = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    let target = app?.pathExtension == "app" ? [app!.path] : ["-b", "com.vphone.launchpad"]
    open.arguments = (foreground ? [] : ["-g", "-j"]) + target
    open.standardOutput = FileHandle.nullDevice
    open.standardError = FileHandle.nullDevice
    FileHandle.standardError.write(Data("starting vphone-launchpad…\n".utf8))
    do {
        try open.run()
        open.waitUntilExit()
    } catch {
        fail("unable to start vphone-launchpad.", detail: error.localizedDescription)
    }
    for _ in 0 ..< 120 {
        if let fd = connectControl() {
            return fd
        }
        usleep(250_000)
    }
    fail("vphone-launchpad did not open its control socket.", detail: VPhoneLaunchpadControl.socketPath)
}

// MARK: - Main

var words = Array(CommandLine.arguments.dropFirst())
/// --foreground goes before the command, or among the options of any command
/// but exec, whose arguments all belong to vphone-cli.
var foreground = words.first == "--foreground"
if foreground {
    words.removeFirst()
}

if words.isEmpty || ["help", "-h", "--help"].contains(words[0]) {
    print(usage(), terminator: "")
    exit(words.isEmpty ? 1 : 0)
}

let request: VPhoneLaunchpadControlRequest
do {
    request = try VPhoneLaunchpadControlRequest.parse(words, foreground: &foreground)
} catch {
    fail(error.message, detail: error.detail)
}
let fd = connectControl() ?? launchAndConnect(foreground: foreground)

guard var line = try? JSONEncoder().encode(request) else {
    fail("unable to encode the request.")
}

line.append(0x0A)
guard VPhoneLaunchpadControl.write(line, to: fd) else {
    fail("vphone-launchpad closed the connection.")
}

// Interrupting this process closes the socket, which cancels the command in
// the app where the command can be cancelled.
var splitter = Data()
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let count = read(fd, &buffer, buffer.count)
    if count < 0, errno == EINTR {
        continue
    }
    guard count > 0 else {
        break
    }
    splitter.append(contentsOf: buffer[0 ..< count])
    while let newline = splitter.firstIndex(of: 0x0A) {
        let data = splitter[splitter.startIndex ..< newline]
        splitter.removeSubrange(splitter.startIndex ... newline)
        guard let event = try? JSONDecoder().decode(VPhoneLaunchpadControlEvent.self, from: data) else {
            continue
        }
        if let output = event.output {
            FileHandle.standardError.write(Data("\(output)\n".utf8))
        }
        guard event.done == true else {
            continue
        }
        guard event.ok == true else {
            fail(event.error ?? "the command failed.", detail: event.detail)
        }
        print(event.result ?? "null")
        exit(0)
    }
}

fail("vphone-launchpad closed the connection before the command finished.")
