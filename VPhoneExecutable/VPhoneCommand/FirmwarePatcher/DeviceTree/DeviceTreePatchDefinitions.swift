// DeviceTreePatchDefinitions.swift — DeviceTree patch definition types.
//
// The shapes the DeviceTree patch catalogue is written in: a property
// rewrite, a brand-new child node, and the value a property holds.
//
// Historical note: derived from the legacy Python firmware patcher during the Swift migration.

import Foundation

extension DeviceTreePatcher {
    // MARK: - Patch Definitions

    /// A single property patch specification.
    struct PropertyPatch {
        let nodePath: [String]
        let property: String
        let length: Int
        let flags: UInt16
        let value: PropertyValue
        let patchID: String
        let description: String
    }

    /// A patch that adds a brand-new child node under an existing parent.
    /// Used when iPhone17,3 carries a node that vphone600 does not — e.g.
    /// `/device-tree/product/camera`, which `libMobileGestalt` requires to
    /// answer `MGGetBoolAnswer("still-camera")` truthfully.
    struct AddChildNodePatch {
        let parentPath: [String]
        let nodeName: String
        /// Properties to place inside the new node. The `name` property is
        /// added automatically from `nodeName`; do not include it here.
        let properties: [PropertyDefinition]
        let patchID: String
        let description: String

        struct PropertyDefinition {
            let name: String
            let length: Int
            let flags: UInt16
            let value: PropertyValue
        }
    }

    /// The value to write into a device tree property.
    enum PropertyValue {
        case string(String)
        case integer(UInt64)
        /// Raw bytes — used when the property holds a multi-string blob
        /// (NUL-delimited cstrings packed back-to-back, e.g. `compatible`)
        /// where Swift String escaping of embedded NULs is awkward.
        case bytes(Data)
    }
}
