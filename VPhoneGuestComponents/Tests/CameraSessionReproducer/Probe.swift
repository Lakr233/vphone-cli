import SwiftUI

@main struct SessionProbeApp: App {
    var body: some Scene { WindowGroup { ProbeView() } }
}

struct ProbeView: View {
    @State private var status = "Ready"
    var body: some View {
        VStack(spacing: 20) {
            Text("Camera Session Lifetime")
            Text(status)
        }.padding().task {
            status = "Configuring and releasing synthetic sessions"
            DispatchQueue.global(qos: .userInitiated).async {
                let result = RunCameraSessionProbe()
                let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try? result.write(to: documents.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
                DispatchQueue.main.async { status = result }
            }
        }
    }
}
