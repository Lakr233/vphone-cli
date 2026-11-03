import AppKit
import Foundation

/// A preview of the guest's external display, not a copy of the VM window.
/// iOS chooses the content: its native mirror or an application's external scene.
@MainActor
final class VPhoneExternalDisplayWindowController: NSWindowController, NSWindowDelegate {
    private weak var control: VPhoneGuestControl?
    private let imageView = NSImageView()
    private var frames: Task<Void, Never>?
    private var generation = UUID()
    private(set) var isConfiguring = false
    var onDisconnect: (() -> Void)?

    init(control: VPhoneGuestControl) {
        self.control = control
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.backgroundColor = .black
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        imageView.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(imageView)
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func connect(width: Int, height: Int) async throws {
        guard !isConfiguring, let control else { return }
        isConfiguring = true
        defer { isConfiguring = false }
        _ = try await control.call("display.external.configure", params: ["enabled": true, "width": width, "height": height])
        frames?.cancel()
        generation = UUID()
        let current = generation
        let title = "External Display — \(width) × \(height)"
        window?.title = title
        imageView.image = nil
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        frames = Task { [weak self, weak control] in
            while !Task.isCancelled {
                guard let self, let control, generation == current, window?.isVisible == true else { return }
                let started = ContinuousClock.now
                do {
                    let frame = try await control.call("display.external.frame")
                    guard !Task.isCancelled, generation == current else { return }
                    guard let encoded = frame["data"] as? String,
                          let data = Data(base64Encoded: encoded), let image = NSImage(data: data)
                    else { throw NSError(domain: "VPhoneExternalDisplay", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid display frame"]) }
                    imageView.image = image
                    window?.title = title
                } catch {
                    if Task.isCancelled { return }
                    window?.title = "\(title) — \(error.localizedDescription)"
                    try? await Task.sleep(for: .milliseconds(500))
                }
                // Match the 60 Hz monitor without queuing frames. Slow capture
                // naturally reduces the rate instead of accumulating latency.
                let remaining = Duration.nanoseconds(16_666_667) - (ContinuousClock.now - started)
                if remaining > .zero { try? await Task.sleep(for: remaining) }
            }
        }
    }

    func disconnect() {
        generation = UUID()
        frames?.cancel()
        frames = nil
        imageView.image = nil
        let control = control
        Task {
            _ = try? await control?.call("display.external.configure", params: ["enabled": false])
        }
        onDisconnect?()
    }

    func windowWillClose(_: Notification) { disconnect() }
}
