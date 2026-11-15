import Foundation
import IcliKit
import IcliPrivate
import VphonedNative

private func semanticLayout(orientation: Int = 4) -> [String: Any] {
    var report = layout(orientation: orientation)
    var rows = report["monitors"] as! [[String: Any]]
    rows[0]["elements_available"] = true
    rows[0]["elements_truncated"] = false
    rows[0]["application_scenes"] = [["bundle_id": "com.example.reader", "identifier": "reader-scene",
                                       "frame": rows[0]["bounds"]!, "reference_frame": rows[0]["reference_bounds"]!]]
    report["monitors"] = rows
    return report
}

private func resetSemanticInput() {
    LayoutWitness.layout = semanticLayout()
    LayoutWitness.semanticReads = 0
    LayoutWitness.onSemanticRead = nil
    PointInputWitness.points = []
    SemanticInputWitness.foreground = ["bundle_id": "com.example.reader", "verified": true]
    SemanticInputWitness.apps = [["bundle_id": "com.example.reader", "pid": 42]]
    SemanticInputWitness.axPID = 42
    SemanticInputWitness.elements = [
        ["identifier": "reader-controls", "label": "Reader controls", "role": "button", "clickable": true, "x": 587.0, "y": 48.0],
        ["identifier": "inner-edge", "label": "Save note", "role": "button", "clickable": true, "x": 900.0, "y": 300.0],
    ]
    SemanticInputWitness.truncated = false
    SemanticInputWitness.queriedWidths = []
    SemanticInputWitness.afterQuery = nil
}

private func changeMonitor(_ changes: [String: Any]) {
    var rows = LayoutWitness.layout["monitors"] as! [[String: Any]]
    rows[0].merge(changes) { _, new in new }
    LayoutWitness.layout["monitors"] = rows
}

private func changeScene(_ changes: [String: Any]) {
    let row = (LayoutWitness.layout["monitors"] as! [[String: Any]])[0]
    var scenes = row["application_scenes"] as! [[String: Any]]
    scenes[0].merge(changes) { _, new in new }
    changeMonitor(["application_scenes": scenes])
}

func semanticGeometryTests() throws {
    resetSemanticInput()
    // Real guest dispatch, pinned Icli scope and C conversion. The screenshot
    // fallback is 678x466, but AX points belong to the active 951x669 display.
    let result = try GuestMethodArea.dispatch([.make(InterfaceMethod.self, GuestAPI.executeInterface)],
                                             method: "ui.tap_element", params: ["identifier": "reader-controls"], observer: { nil })
    precondition(result["tapped"] as? Bool == true)
    let tap = PointInputWitness.points.last!
    precondition(abs(tap[0] - 48 / 669.0) < 1e-9 && abs(tap[1] - 364 / 951.0) < 1e-9,
                 "semantic tap used capture geometry instead of the AX display")
    precondition(LayoutWitness.application == "com.example.reader" && LayoutWitness.semanticReads == 2)
    precondition(!icli_interface_geometry_current(nil), "semantic tap leaked its geometry override")

    _ = try GuestAPI.executeInterface(.uiTapElement, ["identifier": "inner-edge"])
    let edge = PointInputWitness.points.last!
    precondition(abs(edge[0] - 300 / 669.0) < 1e-9 && abs(edge[1] - 51 / 951.0) < 1e-9)
    let tree = try GuestAPI.executeInterface(.uiTree, [:])
    precondition((tree["elements"] as! [[String: Any]]).count == 2, "AX clipping discarded the inner display's right side")
    for (params, expectedX): ([String: Any], Double) in [
        (["text": "SAVE NOTE", "match": "exact", "role": "control"], 900),
        (["text": "r", "index": 1, "role": "element"], 900),
        (["identifier": "Reader controls", "role": "button"], 587),
    ] {
        let selected = try GuestAPI.executeInterface(.uiTapElement, params)
        precondition((selected["element"] as! [String: Any])["x"] as? Double == expectedX)
    }
    _ = try GuestAPI.executeInterface(.uiWait, ["identifier": "inner-edge", "timeout_ms": 0])
    _ = try GuestAPI.executeInterface(.uiWaitGone, ["identifier": "absent", "timeout_ms": 0])
    precondition(SemanticInputWitness.queriedWidths.allSatisfy { $0 == 951 })
    let observations = LayoutWitness.semanticReads
    _ = try GuestAPI.executeInterface(.uiElementAt, ["x": 500, "y": 300])
    precondition(LayoutWitness.semanticReads == observations && SemanticInputWitness.queriedWidths.last == 678,
                 "point hit testing changed its existing coordinate contract")

    resetSemanticInput()
    SemanticInputWitness.axPID = 43
    rejects { _ = try GuestAPI.executeInterface(.uiTree, [:]) }
    rejects { _ = try GuestAPI.executeInterface(.uiWaitGone, ["identifier": "absent", "timeout_ms": 0]) }
    precondition(PointInputWitness.points.isEmpty)

    let refusals: [() -> Void] = [
        { SemanticInputWitness.foreground["verified"] = false },
        { SemanticInputWitness.apps.append(SemanticInputWitness.apps[0]) },
        { SemanticInputWitness.apps[0]["pid"] = true },
        { SemanticInputWitness.axPID = 43 },
        { SemanticInputWitness.truncated = true },
        { changeMonitor(["elements_available": false]) },
        { changeMonitor(["elements_truncated": true]) },
        { changeMonitor(["application_scenes": []]) },
        { let row = (LayoutWitness.layout["monitors"] as! [[String: Any]])[0]
          let scenes = row["application_scenes"] as! [[String: Any]]
          changeMonitor(["application_scenes": scenes + scenes]) },
        { changeScene(["bundle_id": "com.example.other"]) },
        { changeScene(["identifier": ""]) },
        { changeScene(["frame": ["x": 0, "y": 0, "width": 952, "height": 669]]) },
        { changeScene(["reference_frame": ["x": 0, "y": 0, "width": 669, "height": 952]]) },
        { changeScene(["frame": ["x": 0, "y": 0, "width": 400, "height": 669]]) },
        { LayoutWitness.layout = unorientedLayout() },
        { LayoutWitness.onSemanticRead = { SemanticInputWitness.foreground["bundle_id"] = "com.example.other" } },
        { SemanticInputWitness.afterQuery = { SemanticInputWitness.foreground["bundle_id"] = "com.example.other" } },
        { SemanticInputWitness.afterQuery = { SemanticInputWitness.apps[0]["pid"] = 43 } },
        { SemanticInputWitness.afterQuery = { changeScene(["identifier": "new-scene"]) } },
        { SemanticInputWitness.afterQuery = { changeMonitor(["display_id": 2]) } },
        { SemanticInputWitness.afterQuery = { LayoutWitness.layout = semanticLayout(orientation: 1) } },
    ]
    for (index, change) in refusals.enumerated() {
        resetSemanticInput()
        change()
        rejects { _ = try GuestAPI.executeInterface(.uiTapElement, ["identifier": "reader-controls"]) }
        precondition(PointInputWitness.points.isEmpty, "refusal \(index) sent input")
        precondition(!icli_interface_geometry_current(nil), "refusal \(index) leaked geometry")
    }
    resetSemanticInput()
    SemanticInputWitness.elements = []
    // A fold between polling iterations must acquire new geometry. A fold
    // during an AX query is covered by the refusal cases above.
    LayoutWitness.onSemanticRead = {
        if LayoutWitness.semanticReads == 3 {
            LayoutWitness.layout = semanticLayout(orientation: 1)
            SemanticInputWitness.elements = [["identifier": "portrait-target", "x": 100.0, "y": 900.0]]
        }
    }
    _ = try GuestAPI.executeInterface(.uiWait, ["identifier": "portrait-target", "timeout_ms": 1000])
    precondition(SemanticInputWitness.queriedWidths == [951, 669], "wait reused stale display geometry")
    precondition(PointInputWitness.points.isEmpty && !icli_interface_geometry_current(nil))
    resetSemanticInput()
    print("Semantic handlers bind AX clipping and HID input to one verified foreground scene and display")
}
