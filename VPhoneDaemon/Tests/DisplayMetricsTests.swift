import Foundation

@main
enum DisplayMetricsTests {
    static func main() throws {
        // The iPad observation has a usable display configuration while the
        // layout's interface orientation remains unknown. No portrait or
        // coordinate transform may be inferred from these metrics.
        let fixture = #"""
        {"available":true,"geometry_available":false,"reason":"","monitors":[{
          "available":true,"monitor_source":"default_main","geometry_available":false,
          "interface_orientation":0,"display_id":1,"point_scale":2,
          "bounds":{"x":0,"y":0,"width":744,"height":1133},
          "reference_bounds":{"x":0,"y":0,"width":744,"height":1133}
        }]}
        """#
        let layout = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        let report = GuestDisplayMetrics.report(from: layout)
        precondition(report["available"] as? Bool == true)
        precondition(report["source"] as? String == "frontboard_default_main")
        precondition(report["display_id"] as? Int == 1)
        precondition(report["point_scale"] as? Double == 2)
        precondition((report["bounds"] as? [String: Double])?["width"] == 744)
        precondition((report["reference_bounds"] as? [String: Double])?["height"] == 1133)
        precondition(report["interface_orientation"] == nil && report["geometry_available"] == nil)

        func changingMonitor(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var changed = layout
            var monitor = (changed["monitors"] as! [[String: Any]])[0]
            change(&monitor)
            changed["monitors"] = [monitor]
            return changed
        }
        func refuses(_ input: [String: Any]) {
            let answer = GuestDisplayMetrics.report(from: input)
            precondition(answer["available"] as? Bool == false)
            precondition(!(answer["reason"] as! String).isEmpty)
            precondition(answer["point_scale"] == nil && answer["display_id"] == nil)
        }

        // Orientation belongs to another contract, including when absent or
        // when the upright and reference bounds differ after a rotation.
        for orientation: Any? in [nil, 1, 4] {
            let input = changingMonitor { $0["interface_orientation"] = orientation }
            precondition(GuestDisplayMetrics.report(from: input)["available"] as? Bool == true)
        }
        let rotated = changingMonitor {
            $0["bounds"] = ["x": 0, "y": 0, "width": 1133, "height": 744]
        }
        precondition(GuestDisplayMetrics.report(from: rotated)["available"] as? Bool == true)

        var missing = layout
        missing["available"] = false
        missing["reason"] = "Owned monitor cleanup failed"
        refuses(missing)
        precondition(GuestDisplayMetrics.report(from: missing)["reason"] as? String == "Owned monitor cleanup failed")
        missing["available"] = 1
        refuses(missing)
        missing["available"] = true
        missing["monitors"] = []
        refuses(missing)
        missing["monitors"] = (layout["monitors"] as! [[String: Any]]) + (layout["monitors"] as! [[String: Any]])
        refuses(missing)
        refuses(changingMonitor { $0["monitor_source"] = "shared_display_type" })
        refuses(changingMonitor { $0["available"] = false })
        refuses(changingMonitor { $0["available"] = 1 })
        for invalid: Any in [true, NSNull(), "2", 0, -1, Double.infinity, Double.nan] {
            refuses(changingMonitor { $0["point_scale"] = invalid })
        }
        for invalid: Any in [true, NSNull(), "1", 0, -1, 1.5, Double(UInt32.max) + 1, Double.infinity] {
            refuses(changingMonitor { $0["display_id"] = invalid })
        }
        for field in ["bounds", "reference_bounds"] {
            refuses(changingMonitor { $0.removeValue(forKey: field) })
            for (key, invalid) in [("x", 1.0), ("y", -1.0), ("width", 0.0), ("height", -1.0),
                                   ("width", Double.infinity), ("height", Double.nan)] {
                refuses(changingMonitor {
                    var rect = $0[field] as! [String: Any]
                    rect[key] = invalid
                    $0[field] = rect
                })
            }
            refuses(changingMonitor {
                var rect = $0[field] as! [String: Any]
                rect["width"] = true
                $0[field] = rect
            })
        }
        // A CADisplay with attractive metrics cannot replace a missing or
        // ambiguous FrontBoard source. It is an independent inventory.
        missing["cadisplays"] = [["displayId": 1, "pointScale": 2]]
        refuses(missing)
        print("Display metrics behavior checks passed")
    }
}
