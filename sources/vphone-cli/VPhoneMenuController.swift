import AppKit
import Dynamic
import Foundation
import Virtualization

// MARK: - Menu Controller

@MainActor
class VPhoneMenuController {
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
        print("[menu] WARNING: Could not read _deviceIdentifier, defaulting to 1")
        return 1
    }

    init(vm: VZVirtualMachine) {
        self.vm = vm
        setupMenuBar()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "vphone")
        appMenu.addItem(withTitle: "Quit vphone", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Keys menu — NO key equivalents to avoid intercepting VM keyboard input
        let keysMenuItem = NSMenuItem()
        let keysMenu = NSMenu(title: "Keys")

        keysMenu.addItem(makeItem("Home (Consumer Menu)", action: #selector(sendHome)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Return", action: #selector(sendReturn)))
        keysMenu.addItem(makeItem("Escape", action: #selector(sendEscape)))
        keysMenu.addItem(makeItem("Space", action: #selector(sendSpace)))
        keysMenu.addItem(makeItem("Tab", action: #selector(sendTab)))
        keysMenu.addItem(makeItem("Delete", action: #selector(sendDeleteKey)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Arrow Up", action: #selector(sendArrowUp)))
        keysMenu.addItem(makeItem("Arrow Down", action: #selector(sendArrowDown)))
        keysMenu.addItem(makeItem("Arrow Left", action: #selector(sendArrowLeft)))
        keysMenu.addItem(makeItem("Arrow Right", action: #selector(sendArrowRight)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Power (System Wake)", action: #selector(sendPower)))
        keysMenu.addItem(makeItem("Volume Up", action: #selector(sendVolumeUp)))
        keysMenu.addItem(makeItem("Volume Down", action: #selector(sendVolumeDown)))
        keysMenu.addItem(NSMenuItem.separator())
        keysMenu.addItem(makeItem("Shift (tap)", action: #selector(sendShift)))
        keysMenu.addItem(makeItem("Command (tap)", action: #selector(sendCommand)))

        keysMenuItem.submenu = keysMenu
        mainMenu.addItem(keysMenuItem)

        // Type menu
        let typeMenuItem = NSMenuItem()
        let typeMenu = NSMenu(title: "Type")
        typeMenu.addItem(makeItem("Type ASCII from Clipboard", action: #selector(typeFromClipboard)))
        typeMenuItem.submenu = typeMenu
        mainMenu.addItem(typeMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Send Key via _VZKeyEvent

    /// Send key down + up through _VZKeyEvent → _VZKeyboard.sendKeyEvents: pipeline.
    /// Works for any Apple VK code in the 0x00–0xB2 range (keyboard page keys).
    private func sendKeyPress(keyCode: UInt16) {
        guard let keyboard = firstKeyboard else {
            print("[menu] No keyboard found")
            return
        }

        let down = Dynamic._VZKeyEvent(type: 0, keyCode: keyCode)
        let up = Dynamic._VZKeyEvent(type: 1, keyCode: keyCode)

        guard let downObj = down.asAnyObject, let upObj = up.asAnyObject else {
            print("[menu] Failed to create _VZKeyEvent")
            return
        }

        Dynamic(keyboard).sendKeyEvents([downObj, upObj] as NSArray)
        print("[menu] Sent keyCode 0x\(String(keyCode, radix: 16)) (down+up)")
    }

    // MARK: - Send Key via Direct Vector Injection

    /// Bypass _VZKeyEvent table lookup by calling sendKeyboardEvents:keyboardID:
    /// directly on VZVirtualMachine with a crafted std::vector<uint64_t>.
    ///
    /// Packed format per element: (intermediate_index << 32) | is_key_down
    ///
    /// Intermediate indices from IDA reverse engineering of sendKeyboardEventsHIDReport:
    ///   0x6E → Consumer Volume Down    0x6F → Consumer Volume Up
    ///   0x70 → Consumer Play/Pause     0x71 → Consumer Snapshot
    ///   0x72 → Generic Desktop System Wake
    /// Home/Menu has NO index — not reachable through this pipeline.
    private func sendRawKeyPress(index: UInt64) {
        guard let keyboard = firstKeyboard else {
            print("[menu] No keyboard found")
            return
        }

        let deviceId = keyboardDeviceId(keyboard)
        print("[menu] Sending raw key index=0x\(String(index, radix: 16)) deviceId=\(deviceId)")

        sendRawKeyEvent(index: index, isKeyDown: true, deviceId: deviceId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            sendRawKeyEvent(index: index, isKeyDown: false, deviceId: deviceId)
        }
    }

    private func sendRawKeyEvent(index: UInt64, isKeyDown: Bool, deviceId: UInt32) {
        let packed = (index << 32) | (isKeyDown ? 1 : 0)

        // std::vector<uint64_t> layout: { begin*, end*, cap* }
        let data = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        defer { data.deallocate() }
        data.pointee = packed

        var vec: (UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>)
            = (data, data.advanced(by: 1), data.advanced(by: 1))

        withUnsafeMutablePointer(to: &vec) { vecPtr in
            Dynamic(vm).sendKeyboardEvents(UnsafeMutableRawPointer(vecPtr), keyboardID: deviceId)
        }

        print("[menu] Raw event: packed=0x\(String(packed, radix: 16)) down=\(isKeyDown)")
    }

    // MARK: - Send HID Report via _processHIDReports

    /// Call _processHIDReports:forDevice:deviceType: with properly constructed
    /// std::vector<std::span<const unsigned char>>.
    ///
    /// From IDA RE of VZVirtualMachine._processHIDReports (0x2301b2310):
    ///   void* -> vector{begin*, end*, cap*} -> span[]{data_ptr, length} -> bytes
    ///   The vector is iterated: each span is encoded via XpcEncoder::encode_data
    ///   deviceType 0 = keyboard, 1 = pointing device
    private func sendHIDReport(_ reportBytes: [UInt8], deviceId: UInt32, deviceType: UInt32 = 0) {
        // Level 1: raw HID report bytes
        let reportPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBytes.count)
        for (i, b) in reportBytes.enumerated() { reportPtr[i] = b }

        // Level 2: std::span<const unsigned char> = { data_ptr, length } (16 bytes)
        let spanPtr = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        spanPtr[0] = Int(bitPattern: reportPtr)
        spanPtr[1] = reportBytes.count

        // Level 3: std::vector<span> = { begin, end, cap } (24 bytes)
        let vecPtr = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        let spanRaw = UnsafeRawPointer(spanPtr)
        vecPtr[0] = Int(bitPattern: spanRaw)                   // begin
        vecPtr[1] = Int(bitPattern: spanRaw.advanced(by: 16))  // end (1 span past begin)
        vecPtr[2] = Int(bitPattern: spanRaw.advanced(by: 16))  // cap = end

        Dynamic(vm)._processHIDReports(
            UnsafeRawPointer(vecPtr),
            forDevice: deviceId,
            deviceType: deviceType
        )

        let hex = reportBytes.map { String(format: "0x%02x", $0) }.joined(separator: " ")
        print("[menu] HID report: [\(hex)] deviceId=\(deviceId) type=\(deviceType)")

        vecPtr.deallocate()
        spanPtr.deallocate()
        reportPtr.deallocate()
    }

    /// Send consumer control press + release via raw HID report.
    /// Standard USB Consumer Control report: 2-byte little-endian usage value.
    private func sendConsumerHIDKey(usage: UInt16) {
        guard let keyboard = firstKeyboard else {
            print("[menu] No keyboard found")
            return
        }
        let deviceId = keyboardDeviceId(keyboard)

        // Press: usage in LE
        sendHIDReport([UInt8(usage & 0xFF), UInt8(usage >> 8)], deviceId: deviceId)

        // Release after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            sendHIDReport([0x00, 0x00], deviceId: deviceId)
        }
    }

    // MARK: - Key Actions (Keyboard Page — via _VZKeyEvent)

    @objc private func sendReturn() { sendKeyPress(keyCode: 0x24) }
    @objc private func sendEscape() { sendKeyPress(keyCode: 0x35) }
    @objc private func sendSpace() { sendKeyPress(keyCode: 0x31) }
    @objc private func sendTab() { sendKeyPress(keyCode: 0x30) }
    @objc private func sendDeleteKey() { sendKeyPress(keyCode: 0x33) }
    @objc private func sendArrowUp() { sendKeyPress(keyCode: 0x7E) }
    @objc private func sendArrowDown() { sendKeyPress(keyCode: 0x7D) }
    @objc private func sendArrowLeft() { sendKeyPress(keyCode: 0x7B) }
    @objc private func sendArrowRight() { sendKeyPress(keyCode: 0x7C) }
    @objc private func sendShift() { sendKeyPress(keyCode: 0x38) }
    @objc private func sendCommand() { sendKeyPress(keyCode: 0x37) }

    // MARK: - Key Actions (Consumer/System — via Injection)

    @objc private func sendHome() {
        // Consumer page 0x0C, usage 0x40 (Menu) — via raw HID report to _processHIDReports
        sendConsumerHIDKey(usage: 0x0040)
    }

    @objc private func sendPower() {
        sendRawKeyPress(index: 0x72) // Generic Desktop System Wake
    }

    @objc private func sendVolumeUp() {
        sendRawKeyPress(index: 0x6F) // Consumer Volume Up
    }

    @objc private func sendVolumeDown() {
        sendRawKeyPress(index: 0x6E) // Consumer Volume Down
    }

    // MARK: - Type ASCII from Clipboard

    @objc private func typeFromClipboard() {
        guard let string = NSPasteboard.general.string(forType: .string) else {
            print("[menu] Clipboard has no string")
            return
        }

        print("[menu] Typing \(string.count) characters from clipboard")
        typeString(string)
    }

    private func typeString(_ string: String) {
        guard let keyboard = firstKeyboard else {
            print("[menu] No keyboard found")
            return
        }

        var delay: TimeInterval = 0
        let interval: TimeInterval = 0.02

        for char in string {
            guard let (keyCode, needsShift) = asciiToVK(char) else {
                print("[menu] Skipping unsupported char: '\(char)'")
                continue
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                var events: [AnyObject] = []

                if needsShift {
                    if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: UInt16(0x38)).asAnyObject {
                        events.append(obj)
                    }
                }
                if let obj = Dynamic._VZKeyEvent(type: 0, keyCode: keyCode).asAnyObject {
                    events.append(obj)
                }
                if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: keyCode).asAnyObject {
                    events.append(obj)
                }
                if needsShift {
                    if let obj = Dynamic._VZKeyEvent(type: 1, keyCode: UInt16(0x38)).asAnyObject {
                        events.append(obj)
                    }
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
