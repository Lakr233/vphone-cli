@testable import vphone_cli
import ArgumentParser
import Testing

struct GlobalCodeSignBypassCLITests {
    @Test(arguments: ["less", "regular", "dev"])
    func vmCreateRejectsUnsupportedVariants(_ variant: String) {
        #expect(throws: (any Error).self) {
            try VPhoneVMCreateCommand.parse([
                "test-vm", "--variant", variant, "--global-code-sign-bypass",
            ])
        }
    }

    @Test(arguments: ["jb", "exp"])
    func vmCreateAcceptsSupportedVariants(_ variant: String) throws {
        let command = try VPhoneVMCreateCommand.parse([
            "test-vm", "--variant", variant, "--global-code-sign-bypass",
        ])
        #expect(command.globalCodeSignBypass)
    }

    @Test(arguments: ["less", "regular", "dev"])
    func fwPatchRejectsUnsupportedVariants(_ variant: String) {
        #expect(throws: (any Error).self) {
            try VPhoneFWPatchCommand.parse([
                "test-vm", "--variant", variant, "--global-code-sign-bypass",
            ])
        }
    }

    @Test(arguments: ["jb", "exp"])
    func fwPatchAcceptsSupportedVariants(_ variant: String) throws {
        let command = try VPhoneFWPatchCommand.parse([
            "test-vm", "--variant", variant, "--global-code-sign-bypass",
        ])
        #expect(command.globalCodeSignBypass)
    }

    @Test(arguments: ["less", "regular", "dev"])
    func diagnosticFirmwarePatchRejectsUnsupportedVariants(_ variant: String) {
        #expect(throws: (any Error).self) {
            try PatchFirmwareCLI.parse([
                "--vm-directory", "/tmp/test-vm",
                "--variant", variant,
                "--global-code-sign-bypass",
            ])
        }
    }

    @Test(arguments: ["jb", "exp"])
    func diagnosticFirmwarePatchAcceptsSupportedVariants(_ variant: String) throws {
        let command = try PatchFirmwareCLI.parse([
            "--vm-directory", "/tmp/test-vm",
            "--variant", variant,
            "--global-code-sign-bypass",
        ])
        #expect(command.globalCodeSignBypass)
    }

    @Test func patchComponentAcceptsTXMDiagnostic() throws {
        let command = try PatchComponentCLI.parse([
            "--component", "txm",
            "--input", "/tmp/input",
            "--output", "/tmp/output",
            "--global-code-sign-bypass",
        ])
        #expect(command.globalCodeSignBypass)
    }

    @Test func patchComponentRejectsOtherComponents() {
        #expect(throws: (any Error).self) {
            try PatchComponentCLI.parse([
                "--component", "kernel-base",
                "--input", "/tmp/input",
                "--output", "/tmp/output",
                "--global-code-sign-bypass",
            ])
        }
    }
}
