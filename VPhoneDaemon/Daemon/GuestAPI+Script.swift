import Darwin
import Foundation
import IcliKit
import VphonedNative

// MARK: - Scripting

/// A guest has no shell and the tvos preset has no debugger, so a script run
/// with vphoned's own identity is the only way to reach what the guest keeps
/// to itself. `script.eval` is the one-shot form and `/v1/shell` the
/// interactive one; both run in a session process rather than in the worker,
/// so a script that crashes or never returns ends only its own session.
///
/// `script.eval` takes `{source, timeout_ms?}` and answers
/// `{ok, result | message, output, crashed}`: a script that throws is an answer,
/// not a failed request, and its output comes back either way.
extension GuestAPI {
    static func executeScript(_ m: ScriptMethod, _ params: [String: Any]) throws -> [String: Any] {
        switch m {
        case .scriptEval:
            let source = try string(params, "source")
            return try evaluateScript(source: source, timeout: scriptTimeout(params))
        case .scriptInfo:
            return scriptInfo()
        }
    }

    static func scriptCapabilities() -> [String] {
        // The interactive route runs a program from the bootstrap as well, so
        // it is offered even where the built-in session cannot run.
        probeAvailable() ? ["shell", "script_js"] : ["shell"]
    }

    /// Long enough for a script that waits on a system service, short enough
    /// that a stuck one does not hold a client's request open indefinitely.
    private static func scriptTimeout(_ params: [String: Any]) -> Double {
        let value = number(params, "timeout_ms", default: 30000) / 1000
        guard value.isFinite, value > 0 else { return 30 }
        return min(max(value, 1), 600)
    }

    private static func evaluateScript(source: String, timeout: Double) throws -> [String: Any] {
        guard probeAvailable() else {
            throw GuestAPIError.unavailable("This guest has no JavaScriptCore, so it cannot run a script")
        }
        guard GuestSessionLimit.evaluations.acquire() else {
            throw GuestAPIError.operationFailed(GuestSessionLimit.evaluations.refusal)
        }
        defer { GuestSessionLimit.evaluations.release() }
        var status: Int32 = -1
        guard let reply = source.withCString({ vp_session_evaluate($0, timeout, &status) }) else {
            if errno == ETIMEDOUT {
                throw GuestAPIError.operationFailed(
                    "The script did not finish within \(Int(timeout)) seconds and was stopped",
                )
            }
            throw GuestAPIError.operationFailed("Could not start a session: \(String(cString: strerror(errno)))")
        }
        defer { free(reply) }

        let data = Data(String(cString: reply).utf8)
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              answer["ok"] != nil
        else {
            // The session died before it could answer: how it ended is all
            // there is to report, and it is what a crash looks like here.
            let message = describe(sessionStatus: status)
            return ["ok": false, "crashed": true, "output": "", "message": message, "error": message]
        }
        var result = answer
        result["crashed"] = false
        return result
    }

    private static func describe(sessionStatus status: Int32) -> String {
        guard status >= 0 else { return "The session ended before it answered" }
        let signalled = status & 0x7F
        if signalled != 0 {
            return "The script ended its session on signal \(signalled)"
        }
        return "The session exited with status \((status >> 8) & 0xFF) before it answered"
    }

    private static func scriptInfo() -> [String: Any] {
        // What `/v1/shell?program=` resolves to, so a client can offer only
        // what this guest actually has.
        var programs: [String: Any] = [:]
        for name in ["bash", "sh", "zsh"] {
            if let path = try? GuestShellSessionHandler.resolveProgram(name) {
                programs[name] = path
            }
        }
        return [
            "available": probeAvailable(),
            "engine": "JavaScriptCore",
            "globals": ["ObjC", "api", "fs", "proc", "console", "print", "sleep"],
            "programs": programs,
        ]
    }
}
