import AppKit
import Dynamic
import Foundation
import Virtualization

// MARK: - Key Helper

@MainActor
class VPhoneKeyHelper {
    private let vm: VZVirtualMachine
    private let control: VPhoneControl
    weak var window: NSWindow?

    /// First _VZKeyboard from the VM's internal keyboard array (used by typeString).
    private var firstKeyboard: AnyObject? {
        guard let arr = Dynamic(vm)._keyboards.asObject as? NSArray, arr.count > 0 else { return nil }
        return arr.object(at: 0) as AnyObject
    }

    init(vm: VPhoneVM, control: VPhoneControl) {
        self.vm = vm.virtualMachine
        self.control = control
    }

    // MARK: - Connection Guard

    private func requireConnection() -> Bool {
        if control.isConnected { return true }
        let alert = NSAlert()
        alert.messageText = "vphoned Not Connected"
        alert.informativeText = "The guest agent is not connected. Key injection requires vphoned running inside the VM."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
        return false
    }

    // MARK: - Hardware Keys (Consumer Page 0x0C)

    func sendHome() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0x40)
    }

    func sendPower() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0x30)
    }

    func sendVolumeUp() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0xE9)
    }

    func sendVolumeDown() {
        guard requireConnection() else { return }
        control.sendHIDPress(page: 0x0C, usage: 0xEA)
    }

    // MARK: - Combos

    func sendSpotlight() {
        guard requireConnection() else { return }
        // Cmd+Space: messages are processed sequentially by vphoned
        control.sendHIDDown(page: 0x07, usage: 0xE3) // Cmd down
        control.sendHIDPress(page: 0x07, usage: 0x2C) // Space press
        control.sendHIDUp(page: 0x07, usage: 0xE3) // Cmd up
    }

    // MARK: - Type ASCII from Clipboard

    func typeFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else {
            print("[keys] Clipboard has no string")
            return
        }
        print("[keys] Typing \(string.count) characters from clipboard")
        typeString(string)
    }

    func typeString(_ string: String) {
        guard let keyboard = firstKeyboard else {
            print("[keys] No keyboard found")
            return
        }

        var delay: TimeInterval = 0
        let interval: TimeInterval = 0.02

        for char in string {
            guard let (keyCode, needsShift) = asciiToVK(char) else {
                print("[keys] Skipping unsupported char: '\(char)'")
                continue
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var events: [AnyObject] = []
                if needsShift {
                    if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: UInt16(0x38)).asAnyObject { events.append(obj) }
                }
                if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: keyCode).asAnyObject { events.append(obj) }
                if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: keyCode).asAnyObject { events.append(obj) }
                if needsShift {
                    if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: UInt16(0x38)).asAnyObject { events.append(obj) }
                }
                Dynamic(keyboard).sendKeyEvents(events as NSArray)
            }

            delay += interval
        }
    }

    // MARK: - ASCII → Apple VK Code (US Layout)

    private func asciiToVK(_ char: Character) -> (UInt16, Bool)? {
        switch char {
        case "a": (0x00, false) case "b": (0x0B, false)
        case "c": (0x08, false) case "d": (0x02, false)
        case "e": (0x0E, false) case "f": (0x03, false)
        case "g": (0x05, false) case "h": (0x04, false)
        case "i": (0x22, false) case "j": (0x26, false)
        case "k": (0x28, false) case "l": (0x25, false)
        case "m": (0x2E, false) case "n": (0x2D, false)
        case "o": (0x1F, false) case "p": (0x23, false)
        case "q": (0x0C, false) case "r": (0x0F, false)
        case "s": (0x01, false) case "t": (0x11, false)
        case "u": (0x20, false) case "v": (0x09, false)
        case "w": (0x0D, false) case "x": (0x07, false)
        case "y": (0x10, false) case "z": (0x06, false)
        case "A": (0x00, true) case "B": (0x0B, true)
        case "C": (0x08, true) case "D": (0x02, true)
        case "E": (0x0E, true) case "F": (0x03, true)
        case "G": (0x05, true) case "H": (0x04, true)
        case "I": (0x22, true) case "J": (0x26, true)
        case "K": (0x28, true) case "L": (0x25, true)
        case "M": (0x2E, true) case "N": (0x2D, true)
        case "O": (0x1F, true) case "P": (0x23, true)
        case "Q": (0x0C, true) case "R": (0x0F, true)
        case "S": (0x01, true) case "T": (0x11, true)
        case "U": (0x20, true) case "V": (0x09, true)
        case "W": (0x0D, true) case "X": (0x07, true)
        case "Y": (0x10, true) case "Z": (0x06, true)
        case "0": (0x1D, false) case "1": (0x12, false)
        case "2": (0x13, false) case "3": (0x14, false)
        case "4": (0x15, false) case "5": (0x17, false)
        case "6": (0x16, false) case "7": (0x1A, false)
        case "8": (0x1C, false) case "9": (0x19, false)
        case "-": (0x1B, false) case "=": (0x18, false)
        case "[": (0x21, false) case "]": (0x1E, false)
        case "\\": (0x2A, false) case ";": (0x29, false)
        case "'": (0x27, false) case ",": (0x2B, false)
        case ".": (0x2F, false) case "/": (0x2C, false)
        case "`": (0x32, false)
        case "!": (0x12, true) case "@": (0x13, true)
        case "#": (0x14, true) case "$": (0x15, true)
        case "%": (0x17, true) case "^": (0x16, true)
        case "&": (0x1A, true) case "*": (0x1C, true)
        case "(": (0x19, true) case ")": (0x1D, true)
        case "_": (0x1B, true) case "+": (0x18, true)
        case "{": (0x21, true) case "}": (0x1E, true)
        case "|": (0x2A, true) case ":": (0x29, true)
        case "\"": (0x27, true) case "<": (0x2B, true)
        case ">": (0x2F, true) case "?": (0x2C, true)
        case "~": (0x32, true)
        case " ": (0x31, false) case "\t": (0x30, false)
        case "\n": (0x24, false) case "\r": (0x24, false)
        default: nil
        }
    }
}
