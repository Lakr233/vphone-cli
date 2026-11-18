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
public func vp_hid_touch_edge(_ phase: Int32, _ x: Double, _ y: Double, _ edge: Int32) { LayoutWitness.edgeEvents += 1 }
