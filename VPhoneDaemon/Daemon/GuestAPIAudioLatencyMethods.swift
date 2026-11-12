import Foundation

enum AudioLatencyMethod: String, GuestMethod {
    case audioHostLatency = "audio.host_latency"

    var spec: MethodSpec {
        switch self {
        case .audioHostLatency: MethodSpec(.optional("seconds", .number, "Mac output-device latency to store in seconds; omit to read the stored value", min: 0, max: 1), summary: "Read or set the Mac audio output latency the guest adds to its sound timing for lip sync.", result: [.optional("changed", .boolean), .required("seconds", .number)])
        }
    }
}
