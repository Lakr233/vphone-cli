import Testing
@testable import VPhoneCore

struct VirtualMachinePickerTests {
    /// A scripted stdin: pops one line per `read()` call.
    private func reader(_ lines: [String?]) -> () -> String? {
        var i = 0
        return { defer { i += 1 }; return i < lines.count ? lines[i] : nil }
    }

    @Test func `returns provided name unchanged`() throws {
        let out = try VPhoneVirtualMachinePicker.resolve(
            provided: "myvm",
            names: ["a", "b"],
            libraryRoot: "/r",
            isInteractive: true,
            read: { nil },
            write: { _ in },
        )
        #expect(out == "myvm") // no prompt when a name is supplied
    }

    @Test func `non interactive without name throws`() {
        #expect(throws: VPhoneVirtualMachinePickerError.notInteractive) {
            _ = try VPhoneVirtualMachinePicker.resolve(
                provided: nil,
                names: ["a"],
                libraryRoot: "/r",
                isInteractive: false,
                read: { nil },
                write: { _ in },
            )
        }
    }

    @Test func `empty library throws`() {
        #expect(throws: VPhoneVirtualMachinePickerError.emptyLibrary(root: "/r")) {
            _ = try VPhoneVirtualMachinePicker.resolve(
                provided: nil,
                names: [],
                libraryRoot: "/r",
                isInteractive: true,
                read: { nil },
                write: { _ in },
            )
        }
    }

    @Test func `selects by index`() throws {
        let out = try VPhoneVirtualMachinePicker.resolve(
            provided: nil,
            names: ["alpha", "beta", "gamma"],
            libraryRoot: "/r",
            isInteractive: true,
            read: reader(["2"]),
            write: { _ in },
        )
        #expect(out == "beta")
    }

    @Test func `selects by exact name`() throws {
        let out = try VPhoneVirtualMachinePicker.resolve(
            provided: nil,
            names: ["alpha", "beta"],
            libraryRoot: "/r",
            isInteractive: true,
            read: reader(["alpha"]),
            write: { _ in },
        )
        #expect(out == "alpha")
    }

    @Test func `retries then succeeds`() throws {
        // blank, out-of-range, bad-name, then a good index.
        let out = try VPhoneVirtualMachinePicker.resolve(
            provided: nil,
            names: ["alpha", "beta"],
            libraryRoot: "/r",
            isInteractive: true,
            read: reader(["", "9", "nope", "1"]),
            write: { _ in },
        )
        #expect(out == "alpha")
    }

    @Test func `eof aborts`() {
        #expect(throws: VPhoneVirtualMachinePickerError.aborted) {
            _ = try VPhoneVirtualMachinePicker.resolve(
                provided: nil,
                names: ["alpha"],
                libraryRoot: "/r",
                isInteractive: true,
                read: { nil },
                write: { _ in },
            )
        }
    }

    @Test func `too many invalid throws`() {
        #expect(throws: VPhoneVirtualMachinePickerError.invalidSelection) {
            _ = try VPhoneVirtualMachinePicker.resolve(
                provided: nil,
                names: ["alpha"],
                libraryRoot: "/r",
                isInteractive: true,
                maxRetries: 2,
                read: reader(["x", "y", "z"]),
                write: { _ in },
            )
        }
    }
}
