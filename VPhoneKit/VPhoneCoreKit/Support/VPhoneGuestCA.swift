import Darwin
import Foundation

// MARK: - Guest CA host-side core

/// The host-side logic behind `vphone-cli vm ca install/remove/list`: it
/// resolves the target VM bundle, runs every reject check before any socket is
/// opened, calls the guest CA RPCs over the VM's control socket through an
/// injected transport, validates the replies, and formats stdout.
///
/// The ArgumentParser command (`VPhoneVirtualMachineCACommand`) is a thin
/// adapter that supplies `VPhoneHostAutomationProbe.rpc` as the transport and
/// maps ``UsageError`` → exit 2 and ``RuntimeError`` → exit 1, writing each
/// message to stderr. Keeping the logic here, in the library, lets the test
/// target reach it without the non-linkable command binary.
public enum VPhoneGuestCA {
    /// A control-socket RPC, shaped exactly like `VPhoneHostAutomationProbe.rpc`
    /// (method, params, socket path, timeout in seconds). It returns the guest
    /// result object, or throws `VPhoneGuestCallError`.
    public typealias RPC = (
        _ method: String,
        _ params: [String: Any],
        _ socketPath: String,
        _ timeout: Int,
    ) throws -> [String: Any]

    /// The client-side RPC bound (REQ-007/REQ-008): 30 seconds.
    public static let timeoutSeconds = 30
    /// A PEM may not exceed 64 KiB (REQ-006/REQ-008).
    public static let maximumPEMBytes = 64 * 1024
    static let certificateBegin = "-----BEGIN CERTIFICATE-----"
    static let certificateEnd = "-----END CERTIFICATE-----"

    /// A host-side reject (unknown VM, bad PEM, bad sha256): CLI exit 2, no RPC.
    public struct UsageError: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// An RPC, guest, transport, or reply-validation failure: CLI exit 1.
    public struct RuntimeError: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    // MARK: - Public operations

    /// `vm ca install <vmname> <pem-file> [--admin]`: read + validate the PEM
    /// host-side, extract only the single CERTIFICATE block, then
    /// `security.ca_install {pem, force: true[, admin: true]}` — user trust
    /// domain by default, admin when `admin` is set. Validates the reply. Writes
    /// nothing on success.
    public static func install(
        vmName: String,
        library: VPhoneLibrary,
        pemPath: String,
        admin: Bool = false,
        timeout: Int = timeoutSeconds,
        rpc: RPC,
    ) throws {
        let socketPath = try socketPath(vmName: vmName, library: library)
        let pem = try loadInstallPEM(path: pemPath)
        var params: [String: Any] = ["pem": pem, "force": true]
        if admin { params["admin"] = true }
        let reply = try call(
            method: "security.ca_install",
            params: params,
            socketPath: socketPath, vmName: vmName, timeout: timeout, rpc: rpc,
            timeoutTail: "",
        )
        try validateInstallReply(reply)
    }

    /// `vm ca remove <vmname> <sha256>`: validate + lowercase the sha256
    /// host-side, then `security.ca_remove {sha256, force: true}`. Validates the
    /// reply. Writes nothing on success.
    public static func remove(
        vmName: String,
        library: VPhoneLibrary,
        sha256: String,
        timeout: Int = timeoutSeconds,
        rpc: RPC,
    ) throws {
        let socketPath = try socketPath(vmName: vmName, library: library)
        let normalized = try normalizedSHA256(sha256)
        let reply = try call(
            method: "security.ca_remove",
            params: ["sha256": normalized, "force": true],
            socketPath: socketPath, vmName: vmName, timeout: timeout, rpc: rpc,
            timeoutTail: "",
        )
        try validateRemoveReply(reply)
    }

    /// `vm ca list <vmname>`: `security.ca_list {}`, then validate and format
    /// the reply. Returns the full stdout (one TAB line per anchor, each
    /// newline-terminated; empty string for no anchors).
    public static func list(
        vmName: String,
        library: VPhoneLibrary,
        timeout: Int = timeoutSeconds,
        rpc: RPC,
    ) throws -> String {
        let socketPath = try socketPath(vmName: vmName, library: library)
        let result = try call(
            method: "security.ca_list",
            params: [:],
            socketPath: socketPath, vmName: vmName, timeout: timeout, rpc: rpc,
            timeoutTail: "",
        )
        return try formatList(result)
    }

    // MARK: - Host-side validation

    /// A 64-char hex sha256, case-insensitive, normalized to lowercase. Throws a
    /// usage error (exit 2) otherwise.
    public static func normalizedSHA256(_ raw: String) throws -> String {
        let hex = raw.lowercased()
        guard isSHA256Hex(hex) else {
            throw UsageError("sha256 must be 64 hexadecimal characters, got \"\(raw)\"")
        }
        return hex
    }

    /// Read the PEM file, apply the host-side rejects (unreadable, over 64 KiB,
    /// a `BEGIN CERTIFICATE` count other than one, or a BEGIN with no matching
    /// END), and return ONLY the single `-----BEGIN CERTIFICATE-----`…
    /// `-----END CERTIFICATE-----` block — never any other block (e.g. a bundled
    /// `PRIVATE KEY`), so the key in a combined file is not shipped to the guest.
    static func loadInstallPEM(path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw UsageError("cannot read PEM file \(path)")
        }
        guard data.count <= maximumPEMBytes else {
            throw UsageError(
                "PEM file \(path) is \(data.count) bytes; the limit is 64 KiB (\(maximumPEMBytes) bytes)",
            )
        }
        let text = String(decoding: data, as: UTF8.self)
        let count = text.components(separatedBy: certificateBegin).count - 1
        guard count != 0 else {
            throw UsageError(
                "no certificate in PEM file \(path); expected exactly one \(certificateBegin) block",
            )
        }
        guard count == 1 else {
            throw UsageError(
                "PEM file \(path) holds \(count) certificates; install exactly one (the limit is a single certificate)",
            )
        }
        guard let begin = text.range(of: certificateBegin),
              let end = text.range(of: certificateEnd, range: begin.upperBound ..< text.endIndex)
        else {
            throw UsageError(
                "invalid PEM in \(path): the \(certificateBegin) line has no matching \(certificateEnd) line",
            )
        }
        return String(text[begin.lowerBound ..< end.upperBound])
    }

    // MARK: - Reply validation + formatting

    /// Validate a `security.ca_install` reply: 64-hex `sha256`, string
    /// `subject`, and a `domain` of `user` or `admin` (the domain the anchor
    /// landed in). Any violation is a malformed-reply error (exit 1).
    static func validateInstallReply(_ reply: [String: Any]) throws {
        guard let sha256 = reply["sha256"] as? String, isSHA256Hex(sha256),
              reply["subject"] is String,
              let domain = reply["domain"] as? String, domain == "user" || domain == "admin"
        else {
            throw RuntimeError(
                "malformed security.ca_install reply: expected {sha256: 64-hex, subject: string, domain: user|admin}",
            )
        }
    }

    /// Validate a `security.ca_remove` reply: `removed` exactly `true`, 64-hex
    /// `sha256`. Any violation is a malformed-reply error (exit 1).
    static func validateRemoveReply(_ reply: [String: Any]) throws {
        guard (reply["removed"] as? Bool) == true,
              let sha256 = reply["sha256"] as? String, isSHA256Hex(sha256)
        else {
            throw RuntimeError(
                "malformed security.ca_remove reply: expected {removed: true, sha256: 64-hex}",
            )
        }
    }

    /// Validate the `security.ca_list` reply and render stdout. Any violation is
    /// a malformed-reply error (exit 1) with no partial output. The host itself
    /// replaces C0/DEL control chars in each `subject` with a space (REQ-006/008)
    /// rather than trusting guest sanitization.
    static func formatList(_ result: [String: Any]) throws -> String {
        guard let anchors = result["anchors"] as? [Any] else {
            throw RuntimeError(#"malformed security.ca_list reply: missing "anchors" array"#)
        }
        var rows: [(sha256: String, subject: String)] = []
        for element in anchors {
            guard
                let anchor = element as? [String: Any],
                let rawSHA256 = anchor["sha256"] as? String,
                let subject = anchor["subject"] as? String
            else {
                throw RuntimeError(
                    "malformed security.ca_list reply: an anchor is missing a 64-hex sha256 or string subject",
                )
            }
            let hex = rawSHA256.lowercased()
            guard isSHA256Hex(hex) else {
                throw RuntimeError(
                    "malformed security.ca_list reply: sha256 is not 64 hex characters",
                )
            }
            rows.append((hex, sanitize(subject)))
        }
        // Host sorts bytewise on the lowercase-hex sha256, independent of the
        // order the guest returned.
        rows.sort { $0.sha256.utf8.lexicographicallyPrecedes($1.sha256.utf8) }
        guard !rows.isEmpty else { return "" }
        return rows.map { "\($0.sha256)\t\($0.subject)" }.joined(separator: "\n") + "\n"
    }

    // MARK: - Transport

    static func socketPath(vmName: String, library: VPhoneLibrary) throws -> String {
        let bundle: VPhoneBundle
        do {
            bundle = try library.bundle(named: vmName)
        } catch {
            throw UsageError("no VM named \"\(vmName)\"")
        }
        return bundle.url.appendingPathComponent("vphone.sock").path
    }

    /// Run one RPC after proving the control socket is reachable. A socket that
    /// is absent or refuses the connection means the VM is not running (exit 1,
    /// start-the-VM message); a `.transport` failure once connected is the
    /// client timeout; a `.refused` failure surfaces the guest message.
    static func call(
        method: String,
        params: [String: Any],
        socketPath: String,
        vmName: String,
        timeout: Int,
        rpc: RPC,
        timeoutTail: String,
    ) throws -> [String: Any] {
        switch VPhoneUnixSocket.connect(to: socketPath) {
        case let .success(fd):
            close(fd)
        case .failure:
            throw RuntimeError(
                "\(vmName) is not running, or its control socket does not answer. Start it with vm launch.",
            )
        }
        do {
            return try rpc(method, params, socketPath, timeout)
        } catch let error as VPhoneGuestCallError {
            switch error.kind {
            case .transport:
                throw RuntimeError(
                    "\(method) timed out after \(timeout)s; the guest outcome is unknown. "
                        + "Check with vm ca list \(vmName).\(timeoutTail)",
                )
            case .refused:
                throw RuntimeError(error.message)
            }
        }
    }

    // MARK: - Helpers

    private static func isLowercaseHex(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) || ("a" ... "f").contains($0) }
    }

    private static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && isLowercaseHex(s.lowercased())
    }

    /// Replace every C0 control char (0x00–0x1F) or DEL (0x7F) with a single
    /// space, so the one-line TAB-delimited `ca list` format stays unambiguous.
    private static func sanitize(_ subject: String) -> String {
        var out = ""
        for scalar in subject.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F { out.append(" ") }
            else { out.unicodeScalars.append(scalar) }
        }
        return out
    }
}
