import Foundation

enum DeviceMethod: String, GuestMethod {
    case deviceInfo = "device.info"
    case deviceNetwork = "device.network"
    case networkIpv4Get = "network.ipv4.get"
    case networkIpv4Set = "network.ipv4.set"
    case networkResolve = "network.resolve"
    case networkStaticNamesGet = "network.static_names.get"
    case networkStaticNamesSet = "network.static_names.set"
    case networkHostnameGet = "network.hostname.get"
    case networkHostnameSet = "network.hostname.set"
    case deviceNameGet = "device.name.get"
    case deviceNameSet = "device.name.set"
    case deviceIoreg = "device.ioreg"
    case deviceInputDevices = "device.input_devices"
    case deviceDisplays = "device.displays"
    case displayModes = "display.modes"
    case displayLayout = "display.layout"
    case displayMetrics = "display.metrics"
    case displayCaptureActive = "display.capture_active"
    case displayExternalStatus = "display.external.status"
    case displayExternalDiagnostics = "display.external.diagnostics"
    case displayExternalConfigure = "display.external.configure"
    case displayExternalFrame = "display.external.frame"
    case deviceEnvironment = "device.environment"
    case deviceBasebin = "device.basebin"
    case displayBrightness = "display.brightness"
    case displayRotation = "display.rotation"
    case displayOrientation = "display.orientation"
    case displayPosture = "display.posture"
    case displayPose = "display.pose"
    case displayRotationLock = "display.rotation_lock"
    case displayAutoLock = "display.auto_lock"
    case displayAutoLockSet = "display.auto_lock.set"
    case screenUnlock = "screen.unlock"
    case audioVolume = "audio.volume"
    case audioState = "audio.state"
    case networkCapture = "network.capture"
    case securitySslKillswitch = "security.ssl_killswitch"
    case diagnosticsSelfTest = "diagnostics.self_test"
    case notifyPost = "notify.post"
    case notifyState = "notify.state"

    var spec: MethodSpec {
        switch self {
        case .deviceInfo: MethodSpec(summary: "Get a full device snapshot: model, OS, uptime, battery, network, screen, brightness, volume, lock and Developer Mode", result: [.required("agent", .object),
                                              .required("battery", .object),
                                              .required("boot_session_uuid", .string),
                                              .required("boot_time", .number),
                                              .required("brightness", .object),
                                              .required("developer_mode", .object),
                                              .required("device_name", .object),
                                              .required("host", .string),
                                              .required("ios_version", .string),
                                              .required("jailbreak", .object),
                                              .required("kernel", .string),
                                              .required("lock", .object),
                                              .required("low_power_mode", .object),
                                              .required("memory_bytes", .integer),
                                              .required("model", .string),
                                              .required("network", .object),
                                              .required("processor_count", .integer),
                                              .required("rotation", .object),
                                              .required("screen", .object),
                                              .required("storage", .object),
                                              .required("sysname", .string),
                                              .required("uptime_seconds", .number),
                                              .required("volume", .number)])
        case .deviceNetwork: MethodSpec(summary: "List the guest's network interface addresses", result: [.required("addresses", .array)])
        case .networkIpv4Get: MethodSpec(.optional("interface", .string, "Network interface name", default: "en0"), summary: "Read the IPv4 configuration (DHCP or manual, address, router, DNS) of a network interface", result: [.optional("address", .any), .required("dns", .array), .required("interface", .string), .required("managed", .boolean), .required("method", .string), .optional("router", .string), .required("service", .string), .optional("subnet_mask", .any)])
        case .networkIpv4Set:
            MethodSpec(.optional("interface", .string, "Network interface name", default: "en0"),
                       .required("method", .string, "dhcp restores DHCP; manual needs address, subnet_mask, router and dns", values: ["dhcp", "manual"]),
                       .optional("address", .string, "Dotted IPv4 address; required when method is manual"),
                       .optional("subnet_mask", .string, "Dotted IPv4 subnet mask; required when method is manual"),
                       .optional("router", .string, "Dotted IPv4 router address; required when method is manual"),
                       .optional("dns", .array, "Array of dotted IPv4 DNS server addresses for manual; may be empty"), summary: "Set an interface to DHCP or a manual IPv4 address, router and DNS", result: [.optional("address", .any), .required("changed", .boolean), .required("dns", .array), .required("interface", .string), .required("managed", .boolean), .required("method", .string), .optional("router", .string), .required("service", .string), .optional("subnet_mask", .any)])
        case .networkResolve:
            MethodSpec(.required("host", .string, "Host name to resolve"),
                       .optional("port", .integer, "TCP port to connect to for each resolved address; omit to only resolve"),
                       .optional("family", .string, "Restrict results to one address family; omit for both", values: ["ipv4", "ipv6"]),
                       .optional("first_only", .boolean, "Connect-test only the first address", default: false),
                       .optional("timeout_ms", .number, "Milliseconds to wait for the resolver; values under 100 count as 100", default: 5000, min: 100), summary: "Resolve a host name with the guest resolver and optionally test TCP connects to a port", result: [.optional("addresses", .array), .required("elapsed_ms", .integer), .optional("error", .string), .required("host", .string), .optional("status", .string)])
        case .networkStaticNamesGet: MethodSpec(summary: "List the static host name to address entries vphoned serves to the guest", result: [.required("entries", .array)])
        case .networkStaticNamesSet: MethodSpec(.optional("entries", .array, "Array of objects with address (IPv4) and names (array of host names); omit to clear"), summary: "Replace the static host name to address entries; an empty or missing list clears them", result: [.required("changed", .boolean), .required("entries", .array)])
        case .networkHostnameGet: MethodSpec(summary: "Read the guest's mDNS local host name and whether vphoned manages it", result: [.required("local_host_name", .string).nullable(), .required("managed", .boolean)])
        case .networkHostnameSet: MethodSpec(.optional("local_host_name", .string, "New mDNS host name, 1-63 letters, digits and hyphens; omit to restore the original"), summary: "Set the guest's mDNS local host name, or restore the original when omitted", result: [.required("changed", .boolean), .required("local_host_name", .string).nullable(), .required("managed", .boolean)])
        case .deviceNameGet: MethodSpec(summary: "Read the pinned device name shown by Xcode, devicectl and Finder", result: [.required("name", .string).nullable()])
        case .deviceNameSet: MethodSpec(.optional("name", .string, "Device name, not blank, at most 255 UTF-8 bytes, no control characters; null or omitted unpins it"), summary: "Pin the device name shown by Xcode, devicectl and Finder; takes full effect after a guest restart", result: [.required("changed", .boolean), .required("name", .string).nullable(), .required("reboot_required", .boolean)])
        case .deviceIoreg: MethodSpec(.optional("plane", .string, "IORegistry plane to dump", default: "IOService"), summary: "Dump the IORegistry of one plane as JSON entries", result: [.optional("count", .integer),
                                               .required("entries", .array),
                                               .optional("error", .string),
                                               .optional("plane", .string)])
        case .deviceInputDevices: MethodSpec(summary: "List the HID input services the guest sees", result: [.required("available", .boolean),
                                                      .optional("reason", .string),
                                                      .optional("serviceCount", .integer),
                                                      .optional("services", .array)])
        case .deviceDisplays: MethodSpec(summary: "Probe every display-like IOService object and its small properties", result: [.required("displays", .array)])
        case .displayModes: MethodSpec(summary: "Read display bounds, native size and current and available display modes", result: [.required("available", .boolean), .optional("displays", .array), .optional("reason", .string)])
        case .displayLayout: MethodSpec(summary: "Read monitor, CADisplay and display thread geometry", result: [.required("available", .boolean),
                                                .required("geometry_available", .boolean),
                                                .required("reason", .string),
                                                .required("monitors", .array).open(),
                                                .required("cadisplays", .array).open(),
                                                .required("thread", .object).open(),
                                                .required("observation", .object).open(),
                                                .required("capability_failures", .object).open()])
        case .displayMetrics: MethodSpec(summary: "Read the default-main display identity, point bounds and scale without orientation", result: [.required("available", .boolean),
                                                 .required("source", .string),
                                                 .required("reason", .string),
                                                 .optional("display_id", .integer),
                                                 .optional("bounds", .object).open(),
                                                 .optional("reference_bounds", .object).open(),
                                                 .optional("point_scale", .number)])
        case .displayCaptureActive: MethodSpec(summary: "Capture the active display surface as an image with capture diagnostics", result: [.required("available", .boolean),
                                                       .optional("reason", .string),
                                                       .optional("state", .string),
                                                       .optional("format", .string),
                                                       .optional("base64", .string),
                                                       .optional("width", .integer),
                                                       .optional("height", .integer),
                                                       .optional("row_bytes", .integer),
                                                       .optional("surface_bytes", .integer),
                                                       .optional("pixel_format", .string),
                                                       .optional("png_bitmap", .string),
                                                       .optional("color_space", .string),
                                                       .optional("rotation_applied", .integer),
                                                       .optional("resized", .boolean),
                                                       .optional("orientation_mapping_verified", .boolean),
                                                       .optional("color_profile_verified", .boolean),
                                                       .optional("capture_content_verified", .boolean),
                                                       .optional("renderer", .string),
                                                       .optional("renderer_status", .string),
                                                       .optional("source", .object).open(),
                                                       .optional("source_after", .object).open(),
                                                       .optional("identity_binding", .string),
                                                       .optional("attribution_limit", .string)])
        case .displayExternalStatus: MethodSpec(summary: "Read whether the virtual external display is enabled and its size", result: [.required("enabled", .any),
                                                         .optional("error", .string),
                                                         .optional("height", .integer),
                                                         .optional("name", .string),
                                                         .optional("nonce", .string),
                                                         .optional("ok", .boolean),
                                                         .optional("width", .integer)])
        case .displayExternalDiagnostics: MethodSpec(summary: "Read scene, monitor and policy diagnostics for the external display", result: [.optional("available", .boolean),
                                                              .optional("error", .string),
                                                              .optional("externalPolicyClasses", .object),
                                                              .optional("monitor", .string),
                                                              .optional("owners", .object),
                                                              .optional("sceneManager", .string),
                                                              .optional("scenes", .array),
                                                              .optional("transformer", .string),
                                                              .optional("updated", .number)])
        case .displayExternalConfigure:
            MethodSpec(.required("enabled", .boolean, "true connects the virtual external display, false disconnects it"),
                       .optional("width", .integer, "Display width in pixels; checked only when enabling, with height 1920x1080 or 3840x2160", default: 1920),
                       .optional("height", .integer, "Display height in pixels; checked only when enabling, with width 1920x1080 or 3840x2160", default: 1080), summary: "Enable or disable the virtual external display at 1920x1080 or 3840x2160", result: [.optional("enabled", .any),
                                .optional("error", .string),
                                .optional("height", .integer),
                                .optional("name", .string),
                                .optional("nonce", .string),
                                .optional("ok", .boolean),
                                .optional("width", .integer)])
        case .displayExternalFrame: MethodSpec(summary: "Capture one JPEG frame of the external display, base64 encoded", result: [.required("data", .string), .required("mime_type", .string)])
        case .deviceEnvironment: MethodSpec(summary: "Report the jailbreak environment: layout, jbroot, basebin version and bootstrap tools", result: [.required("basebin_version", .string),
                                                     .required("bootstrap_tools_present", .object),
                                                     .required("euid", .integer),
                                                     .required("executable", .string),
                                                     .required("external_tools_used", .object),
                                                     .required("ios_version", .string),
                                                     .required("jbroot", .string).nullable(),
                                                     .required("jbroot_source", .string),
                                                     .required("layout", .string).nullable(),
                                                     .required("maintainer_scripts", .string),
                                                     .required("markers", .array),
                                                     .required("native", .array),
                                                     .required("platform_binary", .boolean),
                                                     .required("rootfs_prefix", .string),
                                                     .required("roothide_runtime_active", .boolean),
                                                     .required("spawns_processes", .boolean)])
        case .deviceBasebin: MethodSpec(.optional("archive", .string, "Guest path of a basebin archive to read the bundled version from; omit to report only the installed one"), summary: "Report the installed basebin version, and compare it with a basebin archive when one is given", result: [.optional("bundled", .string),
                                                 .optional("bundled_present", .boolean),
                                                 .required("installed", .string),
                                                 .required("installed_path", .string),
                                                 .required("installed_present", .boolean),
                                                 .optional("matches", .boolean),
                                                 .optional("update_available", .boolean)])
        case .displayBrightness: MethodSpec(.optional("value", .number, "Brightness to set; omit to only read", min: 0, max: 1), summary: "Read the screen brightness, or set it when value is given", result: [.required("auto", .boolean).nullable(), .required("value", .number)])
        case .displayRotation: MethodSpec(.optional("orientation", .string, "Interface orientation to turn to, as degrees or a name; omit to only read", values: ["0", "90", "180", "270", "portrait", "landscape-left", "landscape-right", "upside-down", "left", "right", "portrait-upside-down"]), summary: "Read the interface rotation, or turn the interface when orientation is given", result: [.optional("accelerometer", .object),
                                                   .required("degrees", .integer),
                                                   .required("device_orientation", .integer),
                                                   .required("locked", .boolean),
                                                   .required("name", .string),
                                                   .optional("requested", .integer)])
        case .displayOrientation: MethodSpec(summary: "Read SpringBoard's interface orientation without a screen capture; cheap to poll", result: [.required("degrees", .integer).nullable(),
                                                      .optional("device_degrees", .integer),
                                                      .optional("fold_angle", .number),
                                                      .optional("screen_off", .boolean),
                                                      .required("source", .string)])
        case .displayPosture:
            MethodSpec(.optional("position", .any, "Fold target: closed, book (100 degrees), open (180), or a number 0-1 as a fraction of 180 degrees"),
                       .optional("duration", .number, "With position: seconds the sweep takes; 0 is an instant swap; omit for the hand-fold time", min: 0, max: 10),
                       .optional("profile", .string, "With position: sweep animation profile; omit for the SpringBoard default", values: ["continuous", "fade"]),
                       .optional("hinge", .any, "Hinge state set at once: ambiguous, closed, partially-open, open-flat, open, or number 0-4; needed without position", min: 0, max: 4),
                       .optional("orientation", .any, "Device orientation: ambiguous, portrait, upside-down, landscape-left, landscape-right, face-up, face-down, or 0-6", default: 1, min: 0, max: 6),
                       .optional("tabletop", .integer, "Tabletop pose value, used only when the guest has no CoreMotion hinge relay", default: 0, min: 0, max: 10),
                       .optional("angle", .number, "Hinge angle in degrees, used when position is absent; otherwise the hinge state sets it", min: 0, max: 180), summary: "Set a foldable guest's fold pose by position or hinge, orientation and tabletop", result: [.required("angle", .number),
                                .required("hinge", .integer),
                                .required("hinge_hid", .object),
                                .required("orientation", .integer),
                                .required("source", .string),
                                .optional("sweep", .object),
                                .required("tabletop", .integer).nullable()])
        case .displayPose: MethodSpec(summary: "Read the foldable device pose: orientation, hinge and tabletop", result: [.required("available", .boolean),
                                               .optional("device_orientation", .integer),
                                               .optional("hinge", .integer),
                                               .optional("orientation", .integer),
                                               .optional("reason", .string),
                                               .optional("tabletop", .integer)])
        case .displayRotationLock: MethodSpec(.required("locked", .boolean, "true locks rotation, false unlocks it"), summary: "Lock or unlock the interface rotation", result: [.required("degrees", .integer),
                                                       .required("device_orientation", .integer),
                                                       .required("locked", .boolean),
                                                       .required("name", .string)])
        case .displayAutoLock: MethodSpec(summary: "Read the Auto-Lock timeout in seconds", result: [.required("auto_lock_seconds", .integer).nullable(), .required("lock_screen_minimum_seconds", .integer).nullable(), .required("never", .boolean)])
        case .displayAutoLockSet: MethodSpec(.required("seconds", .integer, "Auto-Lock timeout in seconds; 0 means never", min: 0, max: 2147483647), summary: "Set the Auto-Lock timeout in seconds; 0 means never", result: [.required("auto_lock_seconds", .integer).nullable(),
                                                      .required("lock_screen_minimum_seconds", .integer).nullable(),
                                                      .required("never", .boolean),
                                                      .required("requested_auto_lock_seconds", .integer)])
        case .screenUnlock: MethodSpec(.optional("passcode", .string, "Device passcode; required when the device is locked and has one"), .optional("timeout", .number, "Seconds to allow the unlock", default: 10, min: 1, max: 60), summary: "Wake the display and pass the Lock Screen, entering the passcode if the device has one", result: [.required("locked", .boolean),
                                                .required("screen_off", .boolean),
                                                .required("was_locked", .boolean),
                                                .required("was_screen_off", .boolean)])
        case .audioVolume: MethodSpec(.optional("value", .number, "Volume to set; omit to only read", min: 0, max: 1), .optional("category", .string, "Audio category whose volume is read or set", default: "Audio/Video"), summary: "Read the volume of an audio category, or set it when value is given", result: [.required("category", .string), .required("volume", .number)])
        case .audioState: MethodSpec(summary: "Read the active audio category, its volume and mute state", result: [.optional("active_category", .string),
                                              .optional("active_muted", .boolean),
                                              .optional("active_volume", .number),
                                              .optional("error", .string)])
        case .networkCapture:
            MethodSpec(.optional("seconds", .number, "Capture duration in seconds", default: 5, min: 1, max: 60),
                       .optional("interface", .string, "Interface to capture on, up to 15 letters, digits or underscores", default: "en0"),
                       .optional("filter", .string, "Capture filter: optional tcp, udp or icmp, then src/dst port N and host A clauses joined with and"), summary: "Capture packets on an interface into a pcap file in the guest and return a summary", result: [.optional("bytes", .integer), .optional("error", .string), .required("file_bytes", .integer), .optional("filter", .string), .optional("interface", .string), .optional("link_type", .string), .optional("packets", .integer), .optional("path", .string), .required("seconds", .number), .optional("summary", .array)])
        case .securitySslKillswitch: MethodSpec(summary: "Report whether the SSL killswitch is present", result: [.required("present", .boolean)])
        case .diagnosticsSelfTest: MethodSpec(summary: "Run the guest's built-in self tests and report passed, failed and skipped", result: [.required("complete", .boolean),
                                                       .required("environment", .object),
                                                       .required("failed", .integer),
                                                       .required("not_tested", .array),
                                                       .required("passed", .integer),
                                                       .required("skipped", .integer),
                                                       .required("status", .integer),
                                                       .required("tests", .array)])
        case .notifyPost: MethodSpec(.required("name", .string, "Darwin notification name"), .optional("state", .any, "State to set before posting: unsigned 64-bit integer or decimal string"), summary: "Post a Darwin notification, optionally setting its state first", result: [
                                         .required("delivered", .boolean),
                                         .required("name", .string),
                                         .required("posted", .boolean),
                                         .optional("state", .integer)])
        case .notifyState: MethodSpec(.required("name", .string, "Darwin notification name"), summary: "Read the state value of a Darwin notification", result: [.required("name", .string), .required("state", .integer)])
        }
    }
}
