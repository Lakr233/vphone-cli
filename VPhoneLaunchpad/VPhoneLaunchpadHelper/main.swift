import Foundation

// launchd starts this on demand for the Mach service named in the embedded
// launchd plist, and SMJobBless has already checked that the client that
// installed it satisfies SMAuthorizedClients. Each connection checks that again.

let delegate = VPhoneLaunchpadHelperListenerDelegate()
let listener = NSXPCListener(machServiceName: VPhoneLaunchpadHelperIdentity.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
