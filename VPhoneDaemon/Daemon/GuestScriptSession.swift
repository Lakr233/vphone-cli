import Darwin
import Foundation
import IcliKit
import VphonedNative

// MARK: - Session Process

/// The `--session` process the worker spawns for one script (`eval`), one
/// interactive session (`repl`) or one program on a terminal (`exec`).
/// Nothing of the worker's startup has run here: a session owns no port and
/// no device, several run at once, and whatever a script does to this process
/// stops at it. Methods that need state the worker set up at startup are the
/// ones a session cannot reach.
///
/// The engine is IcliKit's probe, which runs inline in this process. vphoned
/// adds what icli leaves to the process hosting it: `api()` answers with the
/// guest API instead of icli's read-only set, and `proc.run` runs a program.
enum GuestScriptSession {
    static func run() -> Int32 {
        let arguments = CommandLine.arguments
        switch arguments.count > 2 ? arguments[2] : "" {
        case "eval": return evaluate()
        case "repl": return interact()
        case "exec": return vp_session_exec()
        default: return 64
        }
    }

    // MARK: - One Script

    /// Evaluate what the worker writes to stdin and answer with one JSON line,
    /// `{ok, result | error, output}`; stdout carries nothing else.
    private static func evaluate() -> Int32 {
        // No terminal here, but the group still matters: a timed-out session is
        // killed by its group so that nothing the script started is left behind.
        vp_session_detach()
        let source = readSource()
        _ = installProcess()
        let probe = evaluateProbe(source, api: answer)
        let line = reply(ok: probe.ok, output: probe.output, result: probe.result, error: probe.error)
        let encoded = (try? JSONSerialization.data(withJSONObject: line))
            ?? Data(#"{"ok":false,"error":"The reply could not be encoded","output":""}"#.utf8)
        FileHandle.standardOutput.write(encoded + Data("\n".utf8))
        return probe.ok ? 0 : 65
    }

    /// The answer line: `result` or `error` is present only when the probe produced it. A session that
    /// answers did not crash; the worker reports `crashed: true` itself when none does.
    private static func reply(ok: Bool, output: String, result: String?, error: String?) -> [String: Any] {
        var reply: [String: Any] = ["ok": ok, "output": output, "crashed": false]
        if let result { reply["result"] = result }
        if let error { reply["error"] = error }
        return reply
    }

    /// Everything on stdin, which the worker closes once it has sent the source.
    private static func readSource() -> String {
        var collected = Data()
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(STDIN_FILENO, &bytes, bytes.count)
            if count > 0 {
                if collected.count < 4 << 20 { collected.append(bytes, count: count) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return String(decoding: collected, as: UTF8.self)
    }

    // MARK: - Interactive

    /// The probe's REPL on the session's terminal, until end of input or `.exit`.
    private static func interact() -> Int32 {
        vp_session_detach()
        let started = installProcess()
        guard started.ok else {
            fputs("\(started.error ?? "The session could not start")\n", stderr)
            return 70
        }
        print("vphoned session: api() reaches the guest API; proc.run(path, [args], input) runs a program.")
        return runProbeREPL(api: answer)
    }

    // MARK: - What vphoned Adds

    /// `proc.run` over `api('proc.run')`, under the name scripts already use.
    /// The probe keeps one context per process, so this outlives the call.
    private static func installProcess() -> ProbeResult {
        evaluateProbe("""
        (function (global) {
          global.proc = {
            run: function (path, args, input) {
              return api('proc.run', {path: path, args: args || [], input: input === undefined ? null : input});
            },
          };
        })(this);
        """)
    }

    /// A script's `api(method, params)`: `proc.run`, or any guest API method,
    /// answered in this process.
    private static func answer(_ method: String, _ params: [String: Any]) throws -> Any {
        if method == "proc.run" { return try runProgram(params) }
        do {
            return try GuestAPI.execute(method: method, params: params)
        } catch let error as IcliError {
            throw error
        } catch let error as GuestAPIError {
            throw ProbeAPIError(code: error.code, message: error.description)
        } catch {
            throw ProbeAPIError(code: "operation_failed", message: String(describing: error))
        }
    }

    /// One program, run to its end: `{status, signal, stdout, stderr}`.
    private static func runProgram(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw ProbeAPIError(code: "invalid_request", message: "proc.run needs a program path")
        }
        let words = [path] + (params["args"] as? [Any] ?? []).map { String(describing: $0) }
        var argv: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
        defer { argv.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        var status: Int32 = 0
        var output: UnsafeMutablePointer<CChar>?
        var errors: UnsafeMutablePointer<CChar>?
        defer {
            free(output)
            free(errors)
        }
        func spawn(_ input: UnsafePointer<CChar>?) -> Int32 {
            vp_spawn_collect(path, &argv, input, &status, &output, &errors)
        }
        let failure = if let input = params["input"] as? String {
            input.withCString { spawn($0) }
        } else {
            spawn(nil)
        }
        guard failure == 0 else {
            throw ProbeAPIError(code: "operation_failed", message: "\(path): \(String(cString: strerror(failure)))")
        }
        let signal = status & 0x7F
        return [
            "status": signal == 0 ? (status >> 8) & 0xFF : -1,
            "signal": signal != 0 && signal != 0x7F ? signal : NSNull(),
            "stdout": output.map { String(cString: $0) } ?? "",
            "stderr": errors.map { String(cString: $0) } ?? "",
        ]
    }
}
