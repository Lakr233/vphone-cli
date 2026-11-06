import Darwin
import Foundation

/// darwinOS ships neither a shell nor JavaScriptCore. The default terminal
/// therefore accepts JSON RPC requests, without inventing a shell language.
/// Explicit program sessions still run native research tools on a real PTY.
enum VPhoneDarwinSession {
    static func run() -> Int32 {
        let args = CommandLine.arguments
        guard args.count > 2 else { return 64 }
        if args[2] == "exec" { return vp_session_exec() }
        guard args[2] == "repl" else { return 64 }
        vp_session_detach()
        print("darwinOS research console: enter {\"method\":\"device.info\",\"params\":{}}; .exit closes the session.")
        print("Run a native tool with {\"method\":\"proc.run\",\"params\":{\"path\":\"/bin/ps\",\"args\":[\"aux\"]}}")
        while true {
            fputs("darwinOS> ", stdout)
            fflush(stdout)
            guard let line = readLine(strippingNewline: true), line != ".exit" else { return 0 }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let reply: APIReply
            do { reply = APIWire.execute(try APIWire.decode(Data(line.utf8))) }
            catch { reply = APIWire.error(String(describing: error)) }
            print(String(decoding: reply.data, as: UTF8.self))
        }
    }
}
