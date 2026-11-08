// Drift fixture. Parsed only, never compiled.
enum ClipboardMethod: String {
    case clipboardGet = "clipboard.get"
}
enum DeviceMethod: String {
    case deviceBattery = "device.battery"
    case deviceInfo = "device.info"
    case deviceIoreg = "device.ioreg"
}
enum ProgressMethod: String {
    case progressStatus = "progress.status"
}
