public enum LayoutWitness {
    nonisolated(unsafe) public static var layout: [String: Any] = [:]
    nonisolated(unsafe) public static var reads = 0
    nonisolated(unsafe) public static var edgeEvents = 0
}
public func vp_display_layout() -> [String: Any] { LayoutWitness.reads += 1; return LayoutWitness.layout }
public func vp_hid_touch_edge(_ phase: Int32, _ x: Double, _ y: Double, _ edge: Int32) { LayoutWitness.edgeEvents += 1 }
