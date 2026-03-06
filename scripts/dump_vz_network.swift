import Foundation
import Virtualization
import ObjectiveC

func dumpMethods(of cls: AnyClass) {
    print("Class: \(NSStringFromClass(cls))")
    var numMethods: UInt32 = 0
    if let methods = class_copyMethodList(cls, &numMethods) {
        for i in 0..<Int(numMethods) {
            let method = methods[i]
            let sel = method_getName(method)
            print("  - \(NSStringFromSelector(sel))")
        }
        free(methods)
    }
}

if let cls = NSClassFromString("VZNATNetworkDeviceAttachment") { dumpMethods(of: cls) }
if let cls = NSClassFromString("VZNetworkDeviceAttachment") { dumpMethods(of: cls) }
if let cls = NSClassFromString("VZVirtioNetworkDeviceConfiguration") { dumpMethods(of: cls) }
if let cls = NSClassFromString("VZNetworkDeviceConfiguration") { dumpMethods(of: cls) }
if let cls = NSClassFromString("_VZVirtioNetworkDeviceConfiguration") { dumpMethods(of: cls) }
