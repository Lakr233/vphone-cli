import Foundation
import VPhoneCore

enum VPhoneFirmwareSelection {
    private static var isTTY: Bool { isatty(FileHandle.standardInput.fileDescriptor) != 0 }
    private static func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    /// Resolve `vm create`'s iPhone/cloudOS sources, prompting on a TTY for
    /// whichever component the user didn't pass. Non-interactive or fully
    /// specified → returns the inputs unchanged (fw_prepare defaults fill gaps).
    static func resolve(iphone: String?, cloudos: String?) throws -> VPhoneFirmwareSources {
        try VPhoneFirmwarePicker.resolve(
            iphone: iphone, cloudos: cloudos,
            isInteractive: isTTY,
            read: { readLine(strippingNewline: true) },
            write: { err($0) })
    }
}
