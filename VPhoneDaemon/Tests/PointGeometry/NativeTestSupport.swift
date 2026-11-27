public enum LayoutWitness {
    nonisolated(unsafe) public static var layout: [String: Any] = [:]
    nonisolated(unsafe) public static var reads = 0
    nonisolated(unsafe) public static var edgeEvents = 0
    nonisolated(unsafe) public static var semanticReads = 0
    nonisolated(unsafe) public static var application: String?
    nonisolated(unsafe) public static var onSemanticRead: (() -> Void)?
}
public func vp_display_layout() -> [String: Any] { LayoutWitness.reads += 1; return LayoutWitness.layout }
public func vp_display_layout_for_application(_ bundle: String) -> [String: Any] {
    LayoutWitness.application = bundle
    LayoutWitness.semanticReads += 1
    LayoutWitness.onSemanticRead?()
    return LayoutWitness.layout
}
/// The icli accessibility wrappers: each answers the JSON text a test sets (nil for a NULL result)
/// and records the arguments it was called with.
public enum IcliAXWitness {
    nonisolated(unsafe) public static var elementsJSON: String?
    nonisolated(unsafe) public static var elementAtJSON: String?
    nonisolated(unsafe) public static var elementCalls: [(pid: Int32, max: Int32)] = []
    nonisolated(unsafe) public static var pointCalls: [(pid: Int32, x: Double, y: Double)] = []
}
public func vp_icli_ax_elements(_ pid: Int32, _ maxElements: Int32) -> String? {
    IcliAXWitness.elementCalls.append((pid, maxElements))
    return IcliAXWitness.elementsJSON
}
public func vp_icli_ax_element_at(_ pid: Int32, _ x: Double, _ y: Double) -> String? {
    IcliAXWitness.pointCalls.append((pid, x, y))
    return IcliAXWitness.elementAtJSON
}
public func vp_hid_touch_edge(_ phase: Int32, _ x: Double, _ y: Double, _ edge: Int32) { LayoutWitness.edgeEvents += 1 }
