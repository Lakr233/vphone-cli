import CoreMediaIO
import Foundation

let source = VPhoneCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: source.provider)
CFRunLoopRun()
