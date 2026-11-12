import Foundation

enum CoreMethod: String, GuestMethod {
    case deviceSnapshot = "device.snapshot"
    case deviceScreen = "device.screen"
    case screenScreenshot = "screen.screenshot"
    case appsList = "apps.list"
    case appsSearch = "apps.search"
    case appsRefresh = "apps.refresh"
    case appsLaunch = "apps.launch"
    case appsTerminate = "apps.terminate"
    case appsUninstall = "apps.uninstall"
    case appsForeground = "apps.foreground"
    case appsOpenUrl = "apps.open_url"
    case appsInstall = "apps.install"
    case bootstrapInstall = "bootstrap.install"
    case bootstrapPackages = "bootstrap.packages"
    case bootstrapStatus = "bootstrap.status"
    case bootstrapInspect = "bootstrap.inspect"
    case bootstrapUninstall = "bootstrap.uninstall"
    case bootstrapFirmware = "bootstrap.firmware"
    case inputTouch = "input.touch"
    case inputTouch2 = "input.touch2"
    case inputPointer = "input.pointer"
    case inputScroll = "input.scroll"
    case inputHid = "input.hid"
    case locationSet = "location.set"
    case locationClear = "location.clear"
    case locationCurrent = "location.current"
    case developerModeStatus = "developer_mode.status"
    case developerModeEnable = "developer_mode.enable"
    case powerLowPowerMode = "power.low_power_mode"
    case locationServices = "location.services"
    case clipboardGet = "clipboard.get"
    case clipboardSet = "clipboard.set"
    case clipboardClear = "clipboard.clear"
    case filesList = "files.list"
    case filesMkdir = "files.mkdir"
    case filesRemove = "files.remove"
    case filesRename = "files.rename"
    case settingsGet = "settings.get"
    case settingsSet = "settings.set"
    case settingsDelete = "settings.delete"
    case keychainList = "keychain.list"
    case keychainAdd = "keychain.add"
    case keychainGet = "keychain.get"
    case keychainUpdate = "keychain.update"
    case keychainDelete = "keychain.delete"
    case agentApplyUpdate = "agent.apply_update"
    case methodsList = "methods.list"

    var spec: MethodSpec {
        switch self {
        case .deviceSnapshot: MethodSpec(summary: "Get a one-call device overview: model, OS, kernel, memory, battery, lock state, storage, jailbreak.", result: [.required("battery", .object),
                                                  .required("boot_session_uuid", .string),
                                                  .required("boot_time", .number),
                                                  .required("host", .string),
                                                  .required("ios_version", .string),
                                                  .required("jailbreak", .object),
                                                  .required("kernel", .string),
                                                  .required("lock", .object),
                                                  .required("memory_bytes", .integer),
                                                  .required("model", .string),
                                                  .required("processor_count", .integer),
                                                  .required("storage", .object),
                                                  .required("sysname", .string),
                                                  .required("uptime_seconds", .number)])
        case .deviceScreen: MethodSpec(summary: "Get screen size in points, scale, orientation, and whether it is locked or off.", result: [.required("height", .number),
                                                .required("locked", .boolean),
                                                .required("orientation", .integer),
                                                .required("scale", .number),
                                                .required("screen_off", .boolean),
                                                .required("width", .number)])
        case .screenScreenshot: MethodSpec(.optional("max_dimension", .integer, "Scale the image down so its longer side is at most this many pixels", min: 1),
                                           .optional("quality", .number, "JPEG quality of a re-encoded image; 0.8 when omitted", default: 0.8, min: 0.1, max: 1.0),
                                           .optional("region", .object, "Crop to {x, y, width, height} in points; the whole screen when omitted"),
                                           summary: "Capture the screen and return it as base64 image data, optionally cropped and scaled.",
                                           result: [.required("bytes", .integer),
                                                    .required("coordinate_scale", .number),
                                                    .required("data", .string),
                                                    .required("height", .integer),
                                                    .required("mime_type", .string),
                                                    .required("point_height", .number),
                                                    .required("point_width", .number),
                                                    .required("region", .object),
                                                    .required("width", .integer)])
        case .appsList: MethodSpec(.optional("filter", .string, "Which apps to list", values: ["all", "running", "user", "system"], default: "all"),
                                    summary: "List installed apps with bundle id, name, version, type, and running state.", result: [.required("apps", .array)])
        case .appsSearch: MethodSpec(.required("query", .string, "Text to match against app names and bundle ids"),
                                      summary: "Search installed apps by name or bundle id.", result: [.required("apps", .array), .required("query", .string)])
        case .appsRefresh: MethodSpec(.optional("directory", .string, "App directory to rescan; the installed bootstrap Applications directory when omitted"),
                                      summary: "Rescan one app directory and register new, changed, or removed apps with the system.", result: [
                                          .required("directory", .string),
                                          .required("failed", .array),
                                          .required("registered", .array),
                                          .required("skipped", .array),
                                          .required("unchanged", .array),
                                          .required("unregistered", .array),
                                          .required("unverified", .array)])
        case .appsLaunch: MethodSpec(.required("bundle_id", .string, "Bundle id of the app to launch"),
                                     .optional("url", .string, "URL to open in the app instead of a plain launch"),
                                     summary: "Launch an app by bundle id, optionally opening a URL, and verify it is frontmost.", result: [
                                         .required("frontmost_verified", .boolean),
                                         .required("pid", .integer),
                                         .optional("warning", .string)])
        case .appsTerminate: MethodSpec(.required("bundle_id", .string, "Bundle id of the app to stop"),
                                        summary: "Send SIGTERM to all processes of an app and wait up to 5 seconds for them to exit.", result: [
                                            .required("already_stopped", .boolean),
                                            .required("killed", .string),
                                            .required("pids", .array)])
        case .appsUninstall:
            MethodSpec(.required("bundle_id", .string, "Bundle id of the app to uninstall"),
                       summary: "Uninstall an app and remove its data containers.",
                       force: .always("uninstall <bundle_id>") { p in try "uninstall \(GuestAPI.string(p, "bundle_id"))" }, result: [
                           .optional("method", .string),
                           .optional("removed_containers", .array),
                           .required("uninstalled", .string)])
        case .appsForeground: MethodSpec(summary: "Get the app currently in the foreground.", result: [
                .required("bundle_id", .string),
                .required("name", .string),
                .required("pid", .integer),
                .required("source", .string),
                .required("verified", .boolean)])
        case .appsOpenUrl: MethodSpec(.required("url", .string, "URL or URL scheme to open"),
                                       .optional("bundle_id", .string, "Bundle id of the app that should handle the URL; the default handler when omitted"),
                                       summary: "Open a URL, optionally in a specific app.", result: [.optional("bundle_id", .string), .required("url", .string)])
        case .appsInstall:
            MethodSpec(.required("path", .string, "Guest path of the IPA file; it is deleted after install"),
                       .optional("cert_path", .string, "Guest path of a signing certificate; deleted after install"),
                       .optional("registration", .string, "Register the app as a System or User app", values: ["System", "User"], default: "User"),
                       summary: "Install an IPA from a guest path, sign it, and register it with the system.", result: [
                           .required("bundle_container", .string),
                           .required("bundle_id", .string),
                           .required("bundle_path", .string),
                           .required("containerized", .boolean),
                           .required("data_container", .string),
                           .required("method", .string),
                           .required("msg", .string),
                           .required("plugins", .array),
                           .required("registration", .string),
                           .required("unregistered_plugins", .array),
                           .required("upgraded", .boolean)])
        case .bootstrapInstall: MethodSpec(.required("layout", .string, "Jailbreak bootstrap layout to install (visionOS supports rootless only)", values: ["rootless", "roothide"]),
                                           .optional("package_path", .string, "Guest path of a local bootstrap package to use instead of downloading"),
                                           summary: "Install the Irisin jailbreak bootstrap; poll bootstrap.status for progress.", result: [
                                               .required("app_path", .string).nullable(),
                                               .required("architecture", .string),
                                               .required("dpkg_database_updated", .boolean),
                                               .required("firmware_version", .string),
                                               .required("jbroot", .string),
                                               .required("layout", .string),
                                               .required("maintainer_scripts_executed", .boolean),
                                               .required("registration", .object).nullable(),
                                               .optional("roothide_base", .object),
                                               .required("service_load", .object),
                                               .optional("service_start", .object),
                                               .optional("service_start_warning", .string),
                                               .required("service_status", .object),
                                               .required("tag", .string),
                                               .required("version", .string)])
        case .bootstrapPackages: MethodSpec(summary: "Install the initial package set into the installed bootstrap.", result: [
                .optional("jbroot", .string),
                .required("packages", .array),
                .optional("repositories", .array),
                .optional("skipped", .string)])
        case .bootstrapStatus: MethodSpec(summary: "Report bootstrap install progress: phase, download bytes, and any error.", result: [
                .optional("downloaded_bytes", .integer),
                .optional("message", .string),
                .optional("jbroot", .string),
                .optional("layout", .string),
                .optional("packages", .array),
                .required("phase", .string),
                .optional("tag", .string),
                .optional("total_bytes", .integer),
                .optional("version", .string)])
        case .bootstrapInspect: MethodSpec(summary: "Report whether a bootstrap is installed, its layout, and its root paths.", result: [
                .required("installed", .boolean),
                .optional("jbroot", .string),
                .optional("layout", .string),
                .required("roots", .array)])
        case .bootstrapUninstall:
            MethodSpec(.optional("roots", .array, "Bootstrap root paths expected to be installed; takes precedence over jbroot"),
                       .optional("jbroot", .string, "Single bootstrap root path; required when roots is omitted"),
                       .optional("reboot", .boolean, "Reboot after removal", default: true),
                       summary: "Remove the installed jailbreak bootstrap, optionally rebooting afterward.",
                       force: .always("uninstall the bootstrap"), result: [
                           .required("deleted", .boolean),
                           .required("reboot_scheduled", .boolean),
                           .required("roots", .array)])
        case .bootstrapFirmware: MethodSpec(summary: "Repair the bootstrap dpkg firmware record to match the running OS version.", result: [
                .required("dpkg_database_updated", .boolean),
                .required("firmware_version", .string),
                .required("jbroot", .string),
                .required("layout", .string)])
        case .inputTouch:
            MethodSpec(.required("phase", .string, "Touch phase", values: ["down", "move", "up"]),
                       .optional("x", .number, "Horizontal position; 0..1 when normalized, else screen points"),
                       .optional("y", .number, "Vertical position; 0..1 when normalized, else screen points"),
                       .optional("edge", .integer, "Edge bitmask: 1 top, 2 bottom, 4 right, 8 left; nonzero starts the touch at that edge; normalized only"),
                       .optional("normalized", .boolean, "True when x and y are fractions of the screen, false for screen points", default: true),
                       summary: "Send a single-finger touch event (down, move, up) at a screen position.", result: [.optional("digitizer_x", .number),
                                .optional("digitizer_y", .number),
                                .optional("edge", .integer),
                                .optional("normalized", .boolean),
                                .required("phase", .string),
                                .optional("x", .number),
                                .optional("y", .number)])
        case .inputTouch2:
            MethodSpec(.required("phase", .string, "Touch phase", values: ["down", "move", "up"]),
                       .optional("x1", .number, "First finger x as a 0..1 fraction of the screen"),
                       .optional("y1", .number, "First finger y as a 0..1 fraction of the screen"),
                       .optional("x2", .number, "Second finger x as a 0..1 fraction of the screen"),
                       .optional("y2", .number, "Second finger y as a 0..1 fraction of the screen"),
                       .optional("normalized", .boolean, "Must be true or omitted; two-finger touch takes normalized coordinates only", default: true),
                       summary: "Send a two-finger touch event, for pinch and rotate gestures.", result: [.required("fingers", .integer), .required("phase", .string)])
        case .inputPointer:
            MethodSpec(.required("x", .number, "Pointer x as a 0..1 fraction of the screen from the top-left", min: 0, max: 1),
                       .required("y", .number, "Pointer y as a 0..1 fraction of the screen from the top-left", min: 0, max: 1),
                       .optional("seq", .integer, "Increasing move number; a move arriving after a higher one is dropped", default: 0, min: 0, max: 9007199254740992),
                       .optional("buttons", .integer, "Held buttons bitmask: 1 primary, 2 secondary, 4 middle", default: 0, min: 0, max: 7),
                       summary: "Move the pointer to a screen position, optionally holding mouse buttons.", result: [.required("buttons", .integer), .required("x", .number), .required("y", .number)])
        case .inputScroll:
            MethodSpec(.required("phase", .string, "Scroll gesture phase", values: ["began", "changed", "ended", "cancelled"]),
                       .optional("dx", .number, "Horizontal scroll delta in points", default: 0, min: -10000, max: 10000),
                       .optional("dy", .number, "Vertical scroll delta in points", default: 0, min: -10000, max: 10000),
                       .optional("x", .number, "Pointer x as a 0..1 fraction to move to before scrolling; needs y", min: 0, max: 1),
                       .optional("y", .number, "Pointer y as a 0..1 fraction to move to before scrolling; needs x", min: 0, max: 1),
                       summary: "Send a pointer scroll event to the view under the pointer.", result: [.required("phase", .string)])
        case .inputHid:
            MethodSpec(.required("page", .integer, "HID usage page, 1 to 65535, for example 7 keyboard or 12 consumer"),
                       .required("usage", .integer, "HID usage code within the page, 1 to 65535"),
                       .optional("long_press", .boolean, "true holds the key until a call with down false; then down is required and page and usage must fit 16 bits"),
                       .optional("down", .boolean, "Send only a press (true) or release (false); a full press and release when omitted"),
                       summary: "Press a hardware key or button by HID usage page and code.", result: [.required("action", .string), .optional("long_press", .boolean), .required("page", .integer), .required("usage", .integer)])
        case .locationSet:
            MethodSpec(.required("latitude", .number, "Latitude in degrees", min: -90, max: 90),
                       .required("longitude", .number, "Longitude in degrees", min: -180, max: 180),
                       .optional("altitude", .number, "Altitude in meters", default: 0, min: -100000, max: 100000),
                       .optional("horizontal_accuracy", .number, "Horizontal accuracy in meters", default: 5, min: 0),
                       .optional("vertical_accuracy", .number, "Vertical accuracy in meters, or -1 for unknown altitude", default: 5),
                       .optional("speed", .number, "Speed in meters per second; unset when omitted", min: 0),
                       .optional("course", .number, "Heading in degrees from 0 up to but not including 360; unset when omitted", min: 0),
                       summary: "Simulate the device location at a coordinate until cleared.", result: [.required("location", .object), .required("simulating", .boolean)])
        case .locationClear: MethodSpec(summary: "Stop simulating location and return to the real one.", result: [.optional("location", .object), .required("simulating", .boolean)])
        case .locationCurrent: MethodSpec(.optional("timeout_ms", .number, "Milliseconds to wait for a fix; more than 0", default: 10000, max: 300000),
                                          summary: "Get the current location fix, simulated or real.", result: [.optional("age_seconds", .number),
                                                   .optional("altitude", .number),
                                                   .optional("client", .string),
                                                   .optional("course", .number),
                                                   .optional("error", .string),
                                                   .optional("fresh", .boolean),
                                                   .optional("horizontal_accuracy", .number),
                                                   .optional("latitude", .number),
                                                   .optional("longitude", .number),
                                                   .optional("simulated", .boolean),
                                                   .optional("speed", .number),
                                                   .optional("timestamp", .string),
                                                   .optional("vertical_accuracy", .number)])
        case .developerModeStatus: MethodSpec(summary: "Report whether developer mode is enabled or armed.", result: [.required("armed", .boolean), .required("enabled", .boolean), .required("writable", .boolean)])
        case .developerModeEnable: MethodSpec(summary: "Enable developer mode; a restart may be required to finish.", result: [.optional("already_enabled", .boolean),
                                                       .required("armed", .boolean),
                                                       .required("enabled", .boolean),
                                                       .optional("restart_required", .boolean),
                                                       .required("writable", .boolean)])
        case .powerLowPowerMode: MethodSpec(.optional("enabled", .boolean, "Turn low power mode on or off; only reads the state when omitted"),
                                            summary: "Get or set low power mode.", result: [.optional("changed", .boolean), .required("enabled", .boolean), .required("method", .string)])
        case .locationServices: MethodSpec(.optional("enabled", .boolean, "Turn location services on or off; only reads the state when omitted"),
                                           summary: "Get or set the system location services switch.", result: [.required("enabled", .boolean)])
        case .clipboardGet: MethodSpec(summary: "Read the system clipboard text and describe any image on it.", result: [
                .required("change_count", .integer),
                .required("has_image", .boolean),
                .required("has_text", .boolean),
                .optional("image", .object),
                .required("items", .integer),
                .required("method", .string),
                .required("text", .string),
                .required("types", .array)])
        case .clipboardSet: MethodSpec(.required("text", .string, "Text to place on the clipboard"),
                                       summary: "Replace the system clipboard contents with text.", result: [
                                           .required("change_count", .integer),
                                           .required("has_image", .boolean),
                                           .required("has_text", .boolean),
                                           .optional("image", .object),
                                           .required("items", .integer),
                                           .required("method", .string),
                                           .required("text", .string),
                                           .required("types", .array)])
        case .clipboardClear: MethodSpec(summary: "Empty the system clipboard.", result: [
                .required("change_count", .integer),
                .required("has_image", .boolean),
                .required("has_text", .boolean),
                .optional("image", .object),
                .required("items", .integer),
                .required("method", .string),
                .required("text", .string),
                .required("types", .array)])
        case .filesList: MethodSpec(.required("path", .string, "Guest directory path to list"),
                                     summary: "List the entries of a guest directory.", result: [.required("entries", .array), .required("path", .string)])
        case .filesMkdir: MethodSpec(.required("path", .string, "Guest directory path to create"),
                                      summary: "Create a guest directory, including any missing parent directories.", result: [.required("created", .boolean), .required("path", .string)])
        case .filesRemove: MethodSpec(.required("path", .string, "Guest file or directory path to delete"),
                                       .optional("recursive", .boolean, "Delete a non-empty directory and everything in it; without it only an empty directory can go", default: false),
                                       summary: "Delete a guest file or directory.", result: [
                                          .optional("message", .string),
                                          .required("path", .string),
                                          .required("removed", .boolean),
                                          .optional("type", .string)])
        case .filesRename: MethodSpec(.required("from", .string, "Existing guest path"),
                                       .required("to", .string, "New guest path; must not exist"),
                                       summary: "Move or rename a guest file or directory; fails if the destination exists.", result: [.required("destination", .string), .required("source", .string)])
        case .settingsGet: MethodSpec(.required("domain", .string, "Preferences domain, for example com.apple.springboard"),
                                      .optional("key", .string, "Preference key; every key in the domain when omitted"),
                                      summary: "Read one preference value or a whole preferences domain.", result: [
                                          .optional("count", .integer),
                                          .required("domain", .string),
                                          .optional("exists", .boolean),
                                          .optional("key", .string),
                                          .optional("type", .string),
                                          .required("user", .string),
                                          .optional("value", .any).open(),
                                          .optional("values", .object).open()])
        case .settingsSet:
            MethodSpec(.required("domain", .string, "Preferences domain, for example com.apple.springboard"),
                       .required("key", .string, "Preference key to write"),
                       .required("value", .any, "Value to store; type json takes an array or object, date epoch seconds or ISO-8601, data Base64"),
                       .optional("type", .string, "Stored value type; inferred from value (bool, float, string, else json) when omitted", values: ["string", "int", "float", "bool", "date", "data", "json"]),
                       summary: "Write a preference value for the mobile user and read it back.", result: [
                           .optional("count", .integer),
                           .required("domain", .string),
                           .optional("exists", .boolean),
                           .optional("key", .string),
                           .optional("notified", .string),
                           .optional("type", .string),
                           .required("user", .string),
                           .optional("value", .any).open(),
                           .optional("values", .object).open()])
        case .settingsDelete: MethodSpec(.required("domain", .string, "Preferences domain"),
                                         .required("key", .string, "Preference key to delete"),
                                         summary: "Delete a preference key for the mobile user.", result: [
                                             .required("domain", .string),
                                             .required("exists", .boolean),
                                             .required("key", .string),
                                             .optional("notified", .string),
                                             .required("removed", .boolean),
                                             .required("user", .string)])
        case .keychainList: MethodSpec(.optional("class", .string, "Keychain item class to list; all classes when omitted", values: ["genp", "inet", "cert", "keys", "idnt"]),
                                       summary: "List keychain items, optionally of one class.", result: [.required("count", .integer), .required("diag", .array), .required("items", .array)])
        case .keychainAdd:
            MethodSpec(.required("account", .string, "Account name of the item"),
                       .required("service", .string, "Service name of the item"),
                       .required("password", .string, "Password to store"),
                       summary: "Add a generic password item to the keychain.", result: [.required("ok", .boolean), .required("status", .integer)])
        case .keychainGet:
            MethodSpec(.optional("class", .string, "Keychain item class", values: ["genp", "inet", "cert", "keys", "idnt"], default: "genp"),
                       .optional("account", .string, "Account attribute; one of account, service, or server is required"),
                       .optional("service", .string, "Service attribute; one of account, service, or server is required"),
                       .optional("server", .string, "Server attribute; one of account, service, or server is required"),
                       .optional("group", .string, "Access group attribute"),
                       .optional("accessGroup", .string, "Alias of group"),
                       summary: "Read the secret value of a keychain item.", result: [.required("ok", .boolean), .required("value", .string).open()])
        case .keychainUpdate:
            MethodSpec(.optional("class", .string, "Keychain item class", values: ["genp", "inet", "cert", "keys", "idnt"], default: "genp"),
                       .required("account", .string, "Account attribute; the item can instead be found by service or server alone"),
                       .optional("service", .string, "Service attribute; one of account, service, or server is required"),
                       .optional("server", .string, "Server attribute; one of account, service, or server is required"),
                       .optional("group", .string, "Access group attribute"),
                       .optional("accessGroup", .string, "Alias of group"),
                       .required("value", .string, "New secret value"),
                       summary: "Replace the secret value of a keychain item.", result: [.required("ok", .boolean)])
        case .keychainDelete:
            MethodSpec(.optional("class", .string, "Keychain item class", values: ["genp", "inet", "cert", "keys", "idnt"], default: "genp"),
                       .optional("account", .string, "Account attribute; one of account, service, or server is required"),
                       .optional("service", .string, "Service attribute; one of account, service, or server is required"),
                       .optional("server", .string, "Server attribute; one of account, service, or server is required"),
                       .optional("group", .string, "Access group attribute"),
                       .optional("accessGroup", .string, "Alias of group"),
                       summary: "Delete a keychain item.", result: [.required("ok", .boolean), .required("removed", .boolean)])
        case .agentApplyUpdate: MethodSpec(.required("sha256", .string, "SHA-256 hex digest of the staged vphoned update"),
                                           summary: "Install the staged vphoned update and restart the agent.", result: [.required("restarting", .boolean)])
        case .methodsList: MethodSpec(summary: "List every method with its description, params, result shape, and force requirement.", result: [.required("methods", .array)])
        }
    }
}
