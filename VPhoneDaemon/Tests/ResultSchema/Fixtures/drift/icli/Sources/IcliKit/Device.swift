public func deviceInfo(detailed: Bool) -> [String: Any] {
    var result: [String: Any] = ["name": "phone", "model": "iPhone"]
    if detailed {
        result["serial"] = "S1"
    }
    return result
}

public func ioregInfo() -> [String: Any] {
    return ["plane": "IOService", "path": "/"]
}
