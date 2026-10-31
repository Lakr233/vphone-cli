import AppKit
import QuartzCore
import VPhoneCoreKit

// MARK: - Display Container

/// The window's content view. It holds the VM view turned to the guest's
/// interface orientation, at the panel's aspect ratio, as large as fits.
///
/// The VM view keeps its portrait bounds under the turn, so touch mapping,
/// which converts window points into those bounds, needs no change: AppKit's
/// conversion undoes the rotation.
final class VPhoneDisplayContainerView: NSView {
    let displayView: NSView
    private let viewportView = NSView()
    var backingPanelSize: NSSize = .zero { didSet { needsLayout = true } }
    /// The guest panel's size in points, portrait.
    var panelSize: NSSize = .zero {
        didSet { needsLayout = true }
    }

    private(set) var orientation: VPhoneDisplayOrientation = .portrait
    /// The drawn turn, counterclockwise in degrees. It differs from
    /// `orientation.viewRotation` only during a turn, and may leave 0...360.
    private var angle: CGFloat = 0
    private var turn: Turn?
    private var displayLink: CADisplayLink?

    private static let turnDuration: CFTimeInterval = 0.35

    /// Black over the panel, above the VM view's layer rather than in its
    /// place, so clicks still reach the VM view (a tap wakes the guest).
    private let darkLayer = CALayer()

    /// Covers the panel while the guest's screen is off: coming on, the
    /// guest's display shows its last frame from before until it draws again,
    /// which after a fold made asleep was the other panel's picture.
    var isScreenDark = false {
        didSet {
            guard isScreenDark != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            darkLayer.opacity = isScreenDark ? 1 : 0
            CATransaction.commit()
        }
    }

    /// One animated turn: the panel's angle and the window frame move
    /// together, so the window reshapes as the panel turns.
    private struct Turn {
        let fromAngle: CGFloat
        let toAngle: CGFloat
        let fromFrame: NSRect?
        let toFrame: NSRect?
        let start: CFTimeInterval
    }

    init(displayView: NSView) {
        self.displayView = displayView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayView.autoresizingMask = []
        viewportView.wantsLayer = true
        viewportView.layer?.masksToBounds = true
        addSubview(viewportView)
        viewportView.addSubview(displayView)
        darkLayer.backgroundColor = NSColor.black.cgColor
        darkLayer.opacity = 0
        darkLayer.zPosition = 1000
        viewportView.layer?.addSublayer(darkLayer)
        installFoldChrome()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Turning

    /// Turns to `orientation`, moving the window to `windowFrame` alongside.
    /// A turn already running continues from where it is drawn.
    func turn(to orientation: VPhoneDisplayOrientation, windowFrame: NSRect?, animated: Bool) {
        self.orientation = orientation
        let target = VPhoneDisplayOrientation.turnTarget(from: angle, to: orientation.viewRotation)
        guard animated, window?.isVisible == true else {
            finishTurn(angle: target, windowFrame: windowFrame)
            return
        }
        turn = Turn(
            fromAngle: angle,
            toAngle: target,
            fromFrame: windowFrame == nil ? nil : window?.frame,
            toFrame: windowFrame,
            start: CACurrentMediaTime(),
        )
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let turning = stepTurn(now: now)
        let folding = stepFold(now: now)
        guard turning || folding else {
            stopDisplayLink()
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Advances the running turn; returns whether one is still running.
    private func stepTurn(now: CFTimeInterval) -> Bool {
        guard let turn else { return false }
        let progress = (now - turn.start) / Self.turnDuration
        guard progress < 1 else {
            self.turn = nil
            finishTurn(angle: turn.toAngle, windowFrame: turn.toFrame)
            return false
        }
        let eased = CGFloat(VPhoneDisplayOrientation.easedProgress(progress))
        angle = turn.fromAngle + (turn.toAngle - turn.fromAngle) * eased
        if let from = turn.fromFrame, let to = turn.toFrame, let window {
            window.setFrame(Self.interpolate(from, to, eased), display: false)
        }
        return true
    }

    private func finishTurn(angle target: CGFloat, windowFrame: NSRect?) {
        angle = target.truncatingRemainder(dividingBy: 360)
        if angle < 0 {
            angle += 360
        }
        if let windowFrame, let window {
            window.setFrame(windowFrame, display: true)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private static func interpolate(_ from: NSRect, _ to: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(
            x: (from.minX + (to.minX - from.minX) * t).rounded(),
            y: (from.minY + (to.minY - from.minY) * t).rounded(),
            width: (from.width + (to.width - from.width) * t).rounded(),
            height: (from.height + (to.height - from.height) * t).rounded(),
        )
    }

    // MARK: - Folding

    /// The fold chrome a foldable guest drives through `display.posture`:
    /// the spine swallowing the screen. The guest's pixels are never scaled
    /// — a single-display guest has no second layout to switch to, and a
    /// host-side squeeze would read as a squashed wallpaper, not a fold.
    /// Instead an opaque spine band grows from the center by exactly the
    /// width a hinge at angle θ would hide from the viewer,
    /// 1 − cos((180−θ)/2): 180° leaves the panel untouched, 100° covers the
    /// middle ~23% (each visible half keeps its native scale, like a book's
    /// angled pages), and 0° closes the band over everything. Touches keep
    /// mapping through the band to the untouched panel underneath.
    private var foldAngle: CGFloat = 180
    private var fold: Fold?
    private let creaseLayer = CAGradientLayer()
    private static let foldDurationFallback: CFTimeInterval = 1.2

    private struct Fold {
        let fromAngle: CGFloat
        let toAngle: CGFloat
        let start: CFTimeInterval
        let duration: CFTimeInterval
    }

    private func installFoldChrome() {
        creaseLayer.frame = .zero
        creaseLayer.startPoint = CGPoint(x: 0, y: 0.5)
        creaseLayer.endPoint = CGPoint(x: 1, y: 0.5)
        // Soft shoulders into an opaque core, so the band reads as a fold
        // shadow rather than a rectangle.
        creaseLayer.colors = [
            NSColor.black.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(0.97).cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.97).cgColor,
            NSColor.black.withAlphaComponent(0).cgColor,
        ]
        creaseLayer.locations = [0, 0.3, 0.5, 0.7, 1]
        creaseLayer.opacity = 0
        layer?.addSublayer(creaseLayer)
    }

    /// The fraction of the panel's width a hinge at `angle` hides from the
    /// viewer: one minus the cosine of each half's tilt.
    private static func hiddenFraction(for angle: CGFloat) -> CGFloat {
        let tilt = (180 - angle) * .pi / 180 / 2
        return 1 - max(cos(tilt), 0)
    }

    /// Folds the chrome to `angle` (0 closed … 180 open) over `duration`
    /// seconds, in step with the guest's own sweep.
    func setFold(angle: Double, duration: Double) {
        let target = CGFloat(min(max(angle, 0), 180))
        let seconds = duration > 0 ? duration : Self.foldDurationFallback
        guard window?.isVisible == true, seconds >= 0.15 else {
            foldAngle = target
            fold = nil
            applyFold()
            return
        }
        fold = Fold(
            fromAngle: foldAngle,
            toAngle: target,
            start: CACurrentMediaTime(),
            duration: seconds,
        )
        if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// Draws the current `foldAngle`: grow or shrink the spine band. The
    /// panel itself is never transformed.
    private func applyFold() {
        creaseLayer.opacity = foldAngle < 179.5 ? 1 : 0
        needsLayout = true
    }

    private func stepFold(now: CFTimeInterval) -> Bool {
        guard let fold else { return false }
        let progress = min(max((now - fold.start) / fold.duration, 0), 1)
        let eased = CGFloat(VPhoneDisplayOrientation.easedProgress(progress))
        foldAngle = fold.fromAngle + (fold.toAngle - fold.fromAngle) * eased
        applyFold()
        if progress >= 1 {
            self.fold = nil
            return false
        }
        return true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let size = panelSize.width > 0
            ? VPhoneDisplayOrientation.fittedSize(panel: panelSize, angle: angle, in: bounds.size)
            : bounds.size
        // Sized unturned, then turned about its center.
        viewportView.frameCenterRotation = 0
        viewportView.frame = NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
let backing = backingPanelSize.width > 0 ? backingPanelSize : panelSize
        let scale = panelSize.width > 0 ? size.width / panelSize.width : 1
        let full = NSSize(width: backing.width * scale, height: backing.height * scale)
        displayView.frameCenterRotation = 0
        displayView.frame = NSRect(x: 0, y: size.height - full.height, width: full.width, height: full.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        darkLayer.frame = viewportView.bounds
        CATransaction.commit()
        viewportView.frameCenterRotation = angle
        if let vmView = displayView as? VPhoneVirtualMachineView {
            vmView.enclosingDisplayRotation = angle
            vmView.activePanelPixels = NSSize(width: panelSize.width * vmView.screenScale,
                                               height: panelSize.height * vmView.screenScale)
        }
        // The spine band hides the folded fraction of the panel and turns
        // with it: laid out in the panel's unturned space, then rotated
        // about the shared center, exactly as the panel is.
        let hidden = Self.hiddenFraction(for: foldAngle)
        let bandWidth = viewportView.frame.width * hidden
        // Animate the frame along the angle steps; keep a hairline floor so
        // the band never flickers between zero-width and the soft shoulder.
        creaseLayer.frame = NSRect(
            x: viewportView.frame.midX - max(bandWidth, 1) / 2,
            y: viewportView.frame.minY,
            width: max(bandWidth, 1),
            height: viewportView.frame.height,
        )
        creaseLayer.transform = CATransform3DMakeRotation(angle * .pi / 180, 0, 0, 1)
    }
}
