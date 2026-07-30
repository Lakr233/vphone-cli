import Foundation
import VPhoneCore

enum VPhoneVMSelection {
    private static var isTTY: Bool { isatty(FileHandle.standardInput.fileDescriptor) != 0 }
    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Resolve an existing-VM name, prompting with a numbered picker when omitted.
    static func resolveExisting(_ provided: String?, in library: VPhoneLibrary) throws -> String {
        if let provided, !provided.isEmpty { return provided }   // supplied name → no library scan
        let names = try library.bundles().map(\.name).sorted()   // no-name path: propagate real scan errors
        return try VPhoneVMPicker.resolve(
            provided: nil, names: names, libraryRoot: library.root.path,
            isInteractive: isTTY,
            read: { readLine(strippingNewline: true) },
            write: { err($0) })
    }

    /// Resolve a NEW name (rename/clone destination): return it if given, else prompt for text.
    static func resolveNewName(_ provided: String?, prompt: String) throws -> String {
        if let provided, !provided.isEmpty { return provided }
        guard isTTY else { throw VPhoneVMPickerError.notInteractive }
        FileHandle.standardError.write(Data((prompt + " ").utf8))
        guard let line = readLine(strippingNewline: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty else {
            throw VPhoneVMPickerError.aborted
        }
        return line
    }
}
