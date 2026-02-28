import AppKit
import Dynamic
import Foundation
import Virtualization

// MARK: - Key Helper

@MainActor
class VPhoneKeyHelper {
    private let vm: VZVirtualMachine

    /// First _VZKeyboard from the VM's internal keyboard array.
    private var firstKeyboard: AnyObject? {
        guard let arr = Dynamic(vm)._keyboards.asObject as? NSArray, arr.count > 0 else { return nil }
        return arr.object(at: 0) as AnyObject
    }

    /// Get _deviceIdentifier from _VZKeyboard via KVC (it's an ivar, not a property).
    private func keyboardDeviceId(_ keyboard: AnyObject) -> UInt32 {
        if let obj = keyboard as? NSObject,
           let val = obj.value(forKey: "_deviceIdentifier") as? UInt32
        {
            return val
        }
        print("[keys] WARNING: Could not read _deviceIdentifier, defaulting to 1")
        return 1
    }

    init(vm: VZVirtualMachine) {
        self.vm = vm
    }

    // MARK: - Send Key via _VZKeyEvent

    /// Send key down + up through _VZKeyEvent → _VZKeyboard.sendKeyEvents: pipeline.
    private func sendKeyPress(keyCode: UInt16) {
        guard let keyboard = firstKeyboard else {
            print("[keys] No keyboard found")
            return
        }

        let down = Dynamic._VZKeyEvent(type: 0, keyCode: keyCode)
        let up = Dynamic._VZKeyEvent(type: 1, keyCode: keyCode)

        guard let downObj = down.asAnyObject, let upObj = up.asAnyObject else {
            print("[keys] Failed to create _VZKeyEvent")
            return
        }

        Dynamic(keyboard).sendKeyEvents([downObj, upObj] as NSArray)
        print("[keys] Sent VK 0x\(String(keyCode, radix: 16)) (down+up)")
    }

    // MARK: - Fn+Key Combos (iOS Full Keyboard Access)

    /// Send modifier+key combo via _VZKeyEvent (mod down → key down → key up → mod up).
    private func sendVKCombo(modifierVK: UInt16, keyVK: UInt16) {
        guard let keyboard = firstKeyboard else {
            print("[keys] No keyboard found")
            return
        }

        var events: [AnyObject] = []
        if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: modifierVK).asAnyObject { events.append(obj) }
        if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: keyVK).asAnyObject { events.append(obj) }
        if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: keyVK).asAnyObject { events.append(obj) }
        if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: modifierVK).asAnyObject { events.append(obj) }

        print("[keys] events: \(events)")
        Dynamic(keyboard).sendKeyEvents(events as NSArray)
        print("[keys] VK combo: 0x\(String(modifierVK, radix: 16))+0x\(String(keyVK, radix: 16))")
    }

    // MARK: - Vector Injection (for keys with no VK code)

    /// Bypass _VZKeyEvent by calling sendKeyboardEvents:keyboardID: directly
    /// with a crafted std::vector<uint64_t>. Packed: (intermediate_index << 32) | is_key_down.
    private func sendRawKeyPress(index: UInt64) {
        guard let keyboard = firstKeyboard else {
            print("[keys] No keyboard found")
            return
        }
        let deviceId = keyboardDeviceId(keyboard)

        sendRawKeyEvent(index: index, isKeyDown: true, deviceId: deviceId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            sendRawKeyEvent(index: index, isKeyDown: false, deviceId: deviceId)
        }
    }

    private func sendRawKeyEvent(index: UInt64, isKeyDown: Bool, deviceId: UInt32) {
        let packed = (index << 32) | (isKeyDown ? 1 : 0)

        let data = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { data.deallocate() }
        data.pointee = packed

        var vec = (data, data.advanced(by: 1), data.advanced(by: 1))
        withUnsafeMutablePointer(to: &vec) { vecPtr in
            _ = Dynamic(vm).sendKeyboardEvents(UnsafeMutableRawPointer(vecPtr), keyboardID: deviceId)
        }
    }

    // MARK: - Named Key Actions

    /// iOS hardware keyboard shortcuts (Cmd-based, Fn has no table entry in _VZKeyEvent)
    func sendHome() {
        sendVKCombo(modifierVK: 0x37, keyVK: 0x04)
    } // Cmd+H → Home Screen
    func sendSpotlight() {
        sendVKCombo(modifierVK: 0x37, keyVK: 0x31)
    } // Cmd+Space → Spotlight

    /// Standard keyboard keys
    func sendReturn() {
        sendKeyPress(keyCode: 0x24)
    }

    func sendEscape() {
        sendKeyPress(keyCode: 0x35)
    }

    func sendSpace() {
        sendKeyPress(keyCode: 0x31)
    }

    func sendTab() {
        sendKeyPress(keyCode: 0x30)
    }

    func sendDeleteKey() {
        sendKeyPress(keyCode: 0x33)
    }

    func sendArrowUp() {
        sendKeyPress(keyCode: 0x7E)
    }

    func sendArrowDown() {
        sendKeyPress(keyCode: 0x7D)
    }

    func sendArrowLeft() {
        sendKeyPress(keyCode: 0x7B)
    }

    func sendArrowRight() {
        sendKeyPress(keyCode: 0x7C)
    }

    func sendShift() {
        sendKeyPress(keyCode: 0x38)
    }

    func sendCommand() {
        sendKeyPress(keyCode: 0x37)
    }

    /// Volume (Apple VK codes)
    func sendVolumeUp() {
        sendKeyPress(keyCode: 0x48)
    }

    func sendVolumeDown() {
        sendKeyPress(keyCode: 0x49)
    }

    /// Power — no VK code, use vector injection (intermediate index 0x72 = System Wake)
    func sendPower() {
        sendRawKeyPress(index: 0x72)
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
