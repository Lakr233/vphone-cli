import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)

let arguments: [String]
if CommandLine.arguments.count > 1 {
    arguments = Array(CommandLine.arguments.dropFirst())
} else {
    let picker = NSOpenPanel()
    picker.title = "Choose a virtual iPhone configuration"
    picker.prompt = "Launch"
    picker.allowedContentTypes = [.propertyList]
    picker.allowsOtherFileTypes = false
    picker.canChooseDirectories = false
    guard picker.runModal() == .OK, let config = picker.url else {
        exit(EXIT_SUCCESS)
    }
    arguments = ["--config", config.path]
}

guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
    fatalError("The application executable has no bundle path")
}
let virtualMachineExecutable = executableDirectory.appendingPathComponent("vphone-vm")
let process = Process()
process.executableURL = virtualMachineExecutable
process.arguments = arguments

do {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let alert = NSAlert()
        alert.messageText = "The virtual iPhone could not start"
        alert.informativeText = "The vphone-vm process exited with status \(process.terminationStatus). Run vphone-cli vm launch in Terminal for the full error."
        alert.runModal()
    }
} catch {
    let alert = NSAlert()
    alert.messageText = "The virtual iPhone could not start"
    alert.informativeText = error.localizedDescription
    alert.runModal()
}
