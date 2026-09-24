import Foundation

public enum VPhoneVirtualMachinePickerError: Error, CustomStringConvertible, Equatable {
    case emptyLibrary(root: String)
    case notInteractive
    case aborted
    case invalidSelection

    public var description: String {
        switch self {
        case let .emptyLibrary(root):
            "No VMs found in \(root). Create one with 'vphone-cli vm create <name>'."
        case .notInteractive:
            "No VM name given, and this is not an interactive terminal. Pass the VM name as an argument."
        case .aborted:
            "Selection cancelled."
        case .invalidSelection:
            "No valid selection. Enter a number from the list, or the exact VM name."
        }
    }
}

public enum VPhoneVirtualMachinePicker {
    /// Resolve an existing-VM name. Returns `provided` unchanged when given;
    /// otherwise shows a numbered menu of `names` and reads a 1-based index or an
    /// exact name. All output goes through `write` (caller routes to stderr); input
    /// via `read` (nil = EOF). I/O is injected so the logic is unit-testable.
    public static func resolve(
        provided: String?,
        names: [String],
        libraryRoot: String,
        isInteractive: Bool,
        maxRetries: Int = 5,
        read: () -> String?,
        write: (String) -> Void,
    ) throws -> String {
        if let provided, !provided.isEmpty {
            return provided
        }
        guard isInteractive else { throw VPhoneVirtualMachinePickerError.notInteractive }
        guard !names.isEmpty else { throw VPhoneVirtualMachinePickerError.emptyLibrary(root: libraryRoot) }

        write("Select a VM:")
        for (i, name) in names.enumerated() {
            write("  [\(i + 1)] \(name)")
        }

        for _ in 0 ..< maxRetries {
            write("Enter number or name: ")
            guard let line = read() else { throw VPhoneVirtualMachinePickerError.aborted }
            let choice = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if choice.isEmpty {
                continue
            }
            if let idx = Int(choice), idx >= 1, idx <= names.count {
                return names[idx - 1]
            }
            if let match = names.first(where: { $0 == choice }) {
                return match
            }
            write("  '\(choice)' is not a valid selection.")
        }
        throw VPhoneVirtualMachinePickerError.invalidSelection
    }
}
