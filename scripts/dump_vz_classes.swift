import Foundation
import ObjectiveC

var numClasses: UInt32 = 0
guard let classes = objc_copyClassList(&numClasses) else { exit(0) }
defer { free(UnsafeMutableRawPointer(classes)) }

for i in 0..<Int(numClasses) {
    let cls: AnyClass = classes[i]
    let name = String(cString: class_getName(cls))
    if name.hasPrefix("VZ") {
        print(name)
    }
}
