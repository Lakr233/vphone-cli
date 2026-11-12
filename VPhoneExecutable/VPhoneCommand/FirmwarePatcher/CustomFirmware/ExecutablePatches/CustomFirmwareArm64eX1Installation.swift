import Foundation
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneSign

/// Reversible installation of optional standalone X1 images. A no-op must not
/// create a backup, re-sign an ordinary arm64e library, or disturb its bundle seal.
public enum CustomFirmwareArm64eX1Installation {
    public enum Outcome: Sendable {
        case applied, notApplicable, inactive, notRevertible
    }

    /// The caller must abort installation, rather than record the prior receipt,
    /// if restoring a failed write also fails. Full installs discard their clone.
    public struct RollbackFailure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func update(
        system: VPhoneConfinedDirectory,
        identifier: String,
        path: String,
        bundle: String?,
        enabled: Bool,
        priorApplied: Bool,
        sealBundle: (String) throws -> Void,
        log: (String) -> Void = { print($0) },
    ) throws -> Outcome {
        let backupPath = path + ".bak"
        if !enabled, !priorApplied, try !system.exists(backupPath) { return .inactive }
        let current = try SavedFile(path, in: system)
        if enabled, current.data == nil {
            log("  [·] \(identifier): optional image absent")
            return .notApplicable
        }
        let backup = try SavedFile(backupPath, in: system)
        if backup.data == nil, priorApplied, current.data != nil {
            log("  [!] \(identifier): no pristine backup; leaving the prior patch in place (not revertible)")
            return .notRevertible
        }
        if !enabled, backup.data == nil { return .inactive }

        var records: [PatchRecord] = []
        var slots = 0
        let name = (path as NSString).lastPathComponent
        let replacement: Data
        if enabled {
            // Start from the original when reapplying. Only a successful, complete
            // lowering earns a backup; the live image is never called pristine.
            guard var data = backup.data ?? current.data else { return .notApplicable }
            // Parse even a no-op: a malformed image is a failure, not evidence
            // that this guest needs no instruction adaptation.
            let signingIdentifier = try VPhoneSigner.identifier(in: data) ?? name
            let entitlements = try VPhoneSigner.entitlements(in: data).first(where: { !$0.isEmpty })
            let outcome = try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&data, identifier: identifier)
            guard !outcome.result.records.isEmpty else {
                guard backup.data == nil || backup.data == current.data else {
                    throw PatcherError.invalidFormat("\(identifier): backup needs no X1 conversion but differs from the live image")
                }
                log("  [·] \(identifier): no X1 conversion needed; original bytes and signature kept")
                return .notApplicable
            }
            records = outcome.result.records
            slots = outcome.slots.count
            // Sign the private buffer before touching the guest.
            replacement = try VPhoneSigner.sign(data, options: .init(
                identifier: signingIdentifier,
                entitlements: entitlements,
                mergesExisting: true,
                style: .appleAdHoc,
            ))
        } else {
            guard let data = backup.data else { return .inactive }
            replacement = data
        }

        let seal = try bundle.map { try SavedFile($0 + "/_CodeSignature/CodeResources", in: system) }
        let signatureDirectory = bundle.map { $0 + "/_CodeSignature" }
        let hadSignatureDirectory = try signatureDirectory.map { try system.exists($0) } ?? false
        do {
            if enabled {
                if backup.data == nil { try system.copyFile(from: path, to: backupPath) }
                try system.writeFile(path, contents: replacement, mode: current.mode, owner: current.owner)
            } else {
                try system.writeFile(path, contents: replacement, mode: backup.mode, owner: backup.owner)
                // The backup itself is a sealed bundle resource. Remove it before
                // computing the restored bundle's seal, retaining it for rollback.
                try system.removeItem(backupPath)
            }
            if let bundle { try sealBundle(bundle) }
        } catch {
            let failure = error
            var rollbackErrors: [String] = []
            for saved in [backup, current] + [seal].compactMap({ $0 }) {
                do { try saved.restore(in: system) }
                catch { rollbackErrors.append(String(describing: error)) }
            }
            if let signatureDirectory, !hadSignatureDirectory {
                do { try system.removeItem(signatureDirectory) }
                catch { rollbackErrors.append(String(describing: error)) }
            }
            if !rollbackErrors.isEmpty {
                throw RollbackFailure(description: "\(identifier): \(failure); rollback failed: \(rollbackErrors.joined(separator: "; "))")
            }
            throw failure
        }
        if enabled {
            for record in records { log(record.description) }
            log("  [+] \(identifier): lowered \(records.count) instructions, re-attested \(slots) slots and signed")
            return .applied
        }
        log("  [+] \(identifier): restored \(path) from backup")
        return .inactive
    }

    private struct SavedFile {
        let path: String
        let data: Data?
        let mode: mode_t
        let owner: (uid: uid_t, gid: gid_t)?

        init(_ path: String, in system: VPhoneConfinedDirectory) throws {
            self.path = path
            if let status = try system.status(path) {
                guard status.st_mode & S_IFMT == S_IFREG else {
                    throw PatcherError.invalidFormat("\(path) is not a regular file")
                }
                data = try system.readData(path)
                mode = status.st_mode & 0o7777
                owner = geteuid() == 0 ? (status.st_uid, status.st_gid) : nil
            } else {
                data = nil
                mode = 0o755
                owner = nil
            }
        }

        func restore(in system: VPhoneConfinedDirectory) throws {
            if let data {
                try system.writeFile(path, contents: data, mode: mode, owner: owner)
            } else {
                try system.removeItem(path)
            }
        }
    }
}
