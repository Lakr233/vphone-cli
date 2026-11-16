import Foundation
import Testing
@testable import VPhoneCoreKit

struct GuestLaunchPlannerTests {
    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    @Test("A path that does not exist throws missingCompanion naming it")
    func missingPath() throws {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/vphone-vm")
        do {
            _ = try VPhoneGuestLaunchPlanner(vphoneVM: missing)
            Issue.record("expected missingCompanion")
        } catch let VPhoneGuestLaunchError.missingCompanion(name, expectedAt) {
            #expect(name == "vphone-vm")
            #expect(expectedAt == missing)
            #expect(VPhoneGuestLaunchError.missingCompanion(name: name, expectedAt: expectedAt)
                .description.contains(missing.path))
        }
    }

    @Test("A file that is not executable throws missingCompanion")
    func notExecutable() throws {
        try withTempDirectory { dir in
            let file = dir.appendingPathComponent("vphone-vm")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect {
                try VPhoneGuestLaunchPlanner(vphoneVM: file)
            } throws: { error in
                guard case let VPhoneGuestLaunchError.missingCompanion(_, url) = error else { return false }
                return url == file
            }
        }
    }

    @Test("An executable without the virtualization entitlements throws missingEntitlements")
    func missingEntitlements() throws {
        try withTempDirectory { dir in
            let file = dir.appendingPathComponent("vphone-vm")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file)
            #expect {
                try VPhoneGuestLaunchPlanner(vphoneVM: file)
            } throws: { error in
                guard case let VPhoneGuestLaunchError.missingEntitlements(guest) = error else { return false }
                return guest == file
            }
        }
    }

    /// A copy of /usr/bin/true ad-hoc signed with the given entitlement keys.
    private func signedCopy(in dir: URL, entitlements: [String]) throws -> URL {
        let file = dir.appendingPathComponent("vphone-vm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: file)
        let plist = dir.appendingPathComponent("ent.plist")
        let body = entitlements.map { "<key>\($0)</key><true/>" }.joined()
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>\(body)</dict></plist>
        """.utf8).write(to: plist)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-f", "-s", "-", "--entitlements", plist.path, file.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0, "codesign failed")
        return file
    }

    private static let both = ["com.apple.private.virtualization", "com.apple.private.virtualization.security-research"]

    @Test("An entitled executable that amfid accepts gives a planner for exactly that path")
    func success() throws {
        try withTempDirectory { dir in
            let file = try signedCopy(in: dir, entitlements: Self.both)
            var probed: [URL] = []
            let planner = try VPhoneGuestLaunchPlanner(vphoneVM: file, amfidRefuses: { probed.append($0); return false })
            #expect(planner.guestExecutable == file)
            #expect(probed == [file])
            let plan = planner.plan(["--config", "x"])
            #expect(plan.executable == file)
            #expect(plan.arguments == ["--config", "x"])
        }
    }

    @Test("Only one of the two virtualization entitlements is not enough")
    func oneEntitlement() throws {
        try withTempDirectory { dir in
            let file = try signedCopy(in: dir, entitlements: [Self.both[0]])
            let entitled = try VPhoneGuestLaunchPlanner.hasRequiredEntitlements(file)
            #expect(!entitled)
            #expect {
                try VPhoneGuestLaunchPlanner(vphoneVM: file, amfidRefuses: { _ in false })
            } throws: { error in
                guard case let VPhoneGuestLaunchError.missingEntitlements(guest) = error else { return false }
                return guest == file
            }
        }
    }

    @Test("When amfid refuses the entitled binary the error carries its path and code-directory hash")
    func blockedByAMFI() throws {
        try withTempDirectory { dir in
            let file = try signedCopy(in: dir, entitlements: Self.both)
            let expected = try #require(VPhoneGuestLaunchPlanner.codeDirectoryHash(of: file))
            #expect(expected.count == 40)
            #expect {
                try VPhoneGuestLaunchPlanner(vphoneVM: file, amfidRefuses: { _ in true })
            } throws: { error in
                guard case let VPhoneGuestLaunchError.blockedByAMFI(guest, cdHash) = error else { return false }
                return guest == file && cdHash == expected
            }
        }
    }

    @Test("The amfid probe: exit 0 passes, SIGKILL is a refusal, any other exit is probeFailed with its output")
    func amfidProbe() throws {
        try withTempDirectory { dir in
            func script(_ body: String) throws -> URL {
                let file = dir.appendingPathComponent("probe-\(UUID().uuidString.prefix(6))")
                try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                return file
            }
            let accepted = try script("exit 0")
            let killed = try script("kill -9 $$")
            let failing = try script("echo oops >&2; exit 3")
            let acceptedRefused = try VPhoneGuestLaunchPlanner.amfidRefuses(accepted)
            let killedRefused = try VPhoneGuestLaunchPlanner.amfidRefuses(killed)
            #expect(!acceptedRefused)
            #expect(killedRefused)
            #expect {
                try VPhoneGuestLaunchPlanner.amfidRefuses(failing)
            } throws: { error in
                guard case let VPhoneGuestLaunchError.probeFailed(code, output) = error else { return false }
                return code == 3 && output == "oops"
            }
        }
    }

    @Test("init() looks for vphone-vm beside the running executable and names that path")
    func defaultInitNamesSibling() throws {
        let sibling = VPhoneResources.siblingExecutable("vphone-vm")
        try #require(!FileManager.default.isExecutableFile(atPath: sibling.path), "test host unexpectedly has a vphone-vm")
        #expect(sibling.lastPathComponent == "vphone-vm")
        #expect {
            try VPhoneGuestLaunchPlanner()
        } throws: { error in
            guard case let VPhoneGuestLaunchError.missingCompanion(name, expectedAt) = error else { return false }
            return name == "vphone-vm" && expectedAt == sibling
        }
    }
}
