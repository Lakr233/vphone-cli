import Foundation

// MARK: - Positions

/// Apple's three screen states, from suiatool's help text shipped in
/// SpringBoardFoundation: `closed` 0°, `book` ~100°, `open` 180°.
enum VPhoneFoldPosition: String, CaseIterable {
    case closed, book, open

    var angle: Double {
        switch self {
        case .closed: 0
        case .book: 100
        case .open: 180
        }
    }

    var title: String {
        switch self {
        case .closed: String(localized: "Closed", bundle: VPhoneLocalization.bundle)
        case .book: String(localized: "Book", bundle: VPhoneLocalization.bundle)
        case .open: String(localized: "fold.posture.open", defaultValue: "Open", bundle: VPhoneLocalization.bundle)
        }
    }
}

/// The hinge states SpringBoard's pose override reports, by the number
/// `display.posture` echoes back.
enum VPhoneFoldHingeState: Int, CaseIterable {
    case ambiguous = 0
    case closed = 1
    case partiallyOpen = 2
    case openFlat = 3
    case open = 4

    init(reported value: Int) {
        self = Self(rawValue: value) ?? .ambiguous
    }

    var title: String {
        switch self {
        case .ambiguous: "ambiguous"
        case .closed: "closed"
        case .partiallyOpen: "partially-open"
        case .openFlat: "open-flat"
        case .open: "open"
        }
    }
}

/// `display.posture`'s reply: the pose the guest accepted and the state of
/// the virtual hinge service beside it.
struct VPhoneFoldReply {
    let position: VPhoneFoldPosition
    /// The angle the guest published, which a sweep settles into.
    let angle: Double
    let hingeState: Int
    /// Whether backboardd's virtual hinge service is enumerated and running.
    let providerRunning: Bool
    /// Whether the sweep reached the service at all (it may be off; the pose
    /// override is the primary and does not fail the call).
    let applied: Bool
    /// The sweep the guest ran, nil when the pose was set instantly.
    let sweepMilliseconds: Double?

    var hinge: VPhoneFoldHingeState {
        VPhoneFoldHingeState(reported: hingeState)
    }
}

// MARK: - Model

/// The three-state fold control: a posture write panel, in the shape of
/// Apple's simulator fold chrome. The guest has no read side for the pose —
/// the state shown is the latest reply.
@MainActor
@Observable
final class VPhoneFoldModel {
    let control: VPhoneGuestControl
    /// Mirrors `control.isConnected`, which is not observable; `run()` keeps it current.
    var isConnected: Bool
    private(set) var isSending = false
    private(set) var reply: VPhoneFoldReply?
    private(set) var status: VPhoneGuestToolStatus?

    /// The screen state the control drives. A pure control, like the
    /// simulator's fold buttons: it starts at the pose a guest boots in.
    var position: VPhoneFoldPosition = .open
    /// Whether the change sweeps through the angles or swaps at once.
    var animates = true
    /// Sweep length in seconds. The guest's own default (opening faster than
    /// closing) is what a closed guest still uses; this panel always names one.
    var duration = 3.0

    var canFold: Bool {
        isConnected && !isSending
    }

    init(control: VPhoneGuestControl) {
        self.control = control
        isConnected = control.isConnected
    }

    /// Keeps `isConnected` current while the view is open.
    func run() async {
        var observed = control.isConnected
        isConnected = observed
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let connected = control.isConnected
            guard connected != observed else { continue }
            observed = connected
            isConnected = connected
        }
    }

    func set(_ target: VPhoneFoldPosition) async {
        guard isConnected, !isSending else { return }
        isSending = true
        do {
            let reply = try await control.setFoldPosition(target, duration: animates ? duration : 0)
            self.reply = reply
            isSending = false
            var message = String(
                localized: "Folded to \(reply.position.title) — \(Int(reply.angle.rounded()))°.",
                bundle: VPhoneLocalization.bundle
            )
            if !reply.providerRunning {
                message += " " + String(localized: "The hinge service is off; only the pose changed.", bundle: VPhoneLocalization.bundle)
            }
            status = VPhoneGuestToolStatus(message: message, isError: false)
        } catch {
            isSending = false
            status = VPhoneGuestToolStatus(
                message: String(
                    localized: "Unable to fold. \(VPhoneControlsModel.guestMessage(error))",
                    bundle: VPhoneLocalization.bundle
                ),
                isError: true,
            )
        }
    }
}
