import AppKit
import Dynamic
import Foundation
import Virtualization

class VPhoneVMView: VZVirtualMachineView {
    var keyHelper: VPhoneKeyHelper?

    override func rightMouseDown(with _: NSEvent) {
        guard let keyHelper else {
            print("[keys] keyHelper was not set, no way home!")
            return
        }
        keyHelper.sendHome()
    }
}
