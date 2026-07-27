@testable import VPhoneCore
import Testing

struct VMPickerTests {
    /// A scripted stdin: pops one line per `read()` call.
    private func reader(_ lines: [String?]) -> () -> String? {
        var i = 0
        return { defer { i += 1 }; return i < lines.count ? lines[i] : nil }
    }

    @Test func returnsProvidedNameUnchanged() throws {
        let out = try VPhoneVMPicker.resolve(
            provided: "myvm", names: ["a", "b"], libraryRoot: "/r", isInteractive: true,
            read: { nil }, write: { _ in })
        #expect(out == "myvm")   // no prompt when a name is supplied
    }

    @Test func nonInteractiveWithoutNameThrows() {
        #expect(throws: VPhoneVMPickerError.notInteractive) {
            _ = try VPhoneVMPicker.resolve(
                provided: nil, names: ["a"], libraryRoot: "/r", isInteractive: false,
                read: { nil }, write: { _ in })
        }
    }

    @Test func emptyLibraryThrows() {
        #expect(throws: VPhoneVMPickerError.emptyLibrary(root: "/r")) {
            _ = try VPhoneVMPicker.resolve(
                provided: nil, names: [], libraryRoot: "/r", isInteractive: true,
                read: { nil }, write: { _ in })
        }
    }

    @Test func selectsByIndex() throws {
        let out = try VPhoneVMPicker.resolve(
            provided: nil, names: ["alpha", "beta", "gamma"], libraryRoot: "/r",
            isInteractive: true, read: reader(["2"]), write: { _ in })
        #expect(out == "beta")
    }

    @Test func selectsByExactName() throws {
        let out = try VPhoneVMPicker.resolve(
            provided: nil, names: ["alpha", "beta"], libraryRoot: "/r",
            isInteractive: true, read: reader(["alpha"]), write: { _ in })
        #expect(out == "alpha")
    }

    @Test func retriesThenSucceeds() throws {
        // blank, out-of-range, bad-name, then a good index.
        let out = try VPhoneVMPicker.resolve(
            provided: nil, names: ["alpha", "beta"], libraryRoot: "/r",
            isInteractive: true, read: reader(["", "9", "nope", "1"]), write: { _ in })
        #expect(out == "alpha")
    }

    @Test func eofAborts() {
        #expect(throws: VPhoneVMPickerError.aborted) {
            _ = try VPhoneVMPicker.resolve(
                provided: nil, names: ["alpha"], libraryRoot: "/r", isInteractive: true,
                read: { nil }, write: { _ in })
        }
    }

    @Test func tooManyInvalidThrows() {
        #expect(throws: VPhoneVMPickerError.invalidSelection) {
            _ = try VPhoneVMPicker.resolve(
                provided: nil, names: ["alpha"], libraryRoot: "/r", isInteractive: true,
                maxRetries: 2, read: reader(["x", "y", "z"]), write: { _ in })
        }
    }
}
