import CoreGraphics
import Testing
@testable import VPhoneCoreKit

/// Issue #525: in full screen the display is letterboxed, and touches were
/// normalized against the whole view, so the bars mapped onto the screen.
struct DisplayGeometryTests {
    /// A 1179x2556 guest at 3x in its own window.
    static let display = CGSize(width: 1179, height: 2556)
    static let window = CGRect(x: 0, y: 0, width: 393, height: 852)
    /// The same guest full screen on a 1512x982 Mac screen.
    static let fullScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    static func geometry(_ bounds: CGRect, flipped: Bool = false) -> VPhoneDisplayGeometry {
        VPhoneDisplayGeometry(viewBounds: bounds, displaySize: display, isFlipped: flipped)
    }

    static func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6
    }

    // MARK: - Display Rect

    @Test func `a window of the display's aspect ratio is all display`() {
        let rect = Self.geometry(Self.window).displayRect
        #expect(abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5)
        #expect(abs(rect.width - 393) < 0.5 && abs(rect.height - 852) < 0.5)
    }

    @Test func `full screen centers the display between bars`() {
        let rect = Self.geometry(Self.fullScreen).displayRect
        #expect(rect.minY == 0 && rect.height == 982)
        let expectedWidth = 982 * 1179.0 / 2556.0
        #expect(abs(rect.width - expectedWidth) < 1e-9)
        #expect(abs(rect.minX - (1512 - expectedWidth) / 2) < 1e-9)
    }

    @Test func `a wide display in a tall view gets bars above and below`() {
        let geometry = VPhoneDisplayGeometry(
            viewBounds: CGRect(x: 0, y: 0, width: 100, height: 400),
            displaySize: CGSize(width: 200, height: 100),
            isFlipped: false,
        )
        #expect(geometry.displayRect == CGRect(x: 0, y: 175, width: 100, height: 50))
    }

    @Test func `an unknown display size falls back to the view`() {
        let geometry = VPhoneDisplayGeometry(viewBounds: Self.fullScreen, displaySize: .zero, isFlipped: false)
        #expect(geometry.displayRect == Self.fullScreen)
    }

    @Test func `resized Duo cover maps visible edges and centre`() {
        let pixels = CGSize(width: 1398, height: 2034)
        for scale in [0.5, 1.0, 717.0 / 678.0, 1.5] {
            let view = CGRect(x: 0, y: 0, width: 466 * scale, height: 678 * scale)
            let viewport = VPhoneDisplayGeometry.activeViewportBounds(
                viewBounds: view, activePixels: pixels, backingPixels: pixels
            )
            let geometry = VPhoneDisplayGeometry(viewBounds: viewport, displaySize: pixels, isFlipped: false)
            #expect(Self.close(geometry.normalizedPoint(CGPoint(x: view.minX, y: view.maxY)), .zero))
            #expect(Self.close(geometry.normalizedPoint(CGPoint(x: view.maxX, y: view.minY)), CGPoint(x: 1, y: 1)))
            #expect(Self.close(geometry.normalizedPoint(CGPoint(x: view.midX, y: view.midY)), CGPoint(x: 0.5, y: 0.5)))
        }
    }

    @Test func `cropped viewport scales with the backing window`() {
        #expect(VPhoneDisplayGeometry.activeViewportBounds(
            viewBounds: CGRect(x: 0, y: 0, width: 800, height: 1200),
            activePixels: CGSize(width: 400, height: 600), backingPixels: CGSize(width: 800, height: 1200)
        ) == CGRect(x: 0, y: 600, width: 400, height: 600))
    }

    // MARK: - Normalizing

    @Test func `full screen display edges normalize to 0 and 1`() {
        let geometry = Self.geometry(Self.fullScreen)
        let rect = geometry.displayRect
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: rect.minX, y: rect.maxY)), CGPoint(x: 0, y: 0)))
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: rect.maxX, y: rect.minY)), CGPoint(x: 1, y: 1)))
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: rect.midX, y: rect.midY)), CGPoint(x: 0.5, y: 0.5)))
    }

    @Test func `points on the bars clamp to the nearest display edge`() {
        let geometry = Self.geometry(Self.fullScreen)
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: 10, y: 491)), CGPoint(x: 0, y: 0.5)))
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: 1500, y: 491)), CGPoint(x: 1, y: 0.5)))
    }

    @Test func `unclamped normalizing keeps a point off the display outside 0 and 1`() {
        let geometry = Self.geometry(Self.fullScreen)
        let rect = geometry.displayRect
        let left = geometry.normalizedPoint(CGPoint(x: rect.minX - rect.width, y: rect.midY), clamped: false)
        #expect(abs(left.x + 1) < 1e-6 && abs(left.y - 0.5) < 1e-6)
        let below = geometry.normalizedPoint(CGPoint(x: rect.midX, y: rect.minY - rect.height), clamped: false)
        #expect(abs(below.x - 0.5) < 1e-6 && abs(below.y - 2) < 1e-6)
    }

    @Test func `a flipped view keeps y down`() {
        let geometry = Self.geometry(Self.fullScreen, flipped: true)
        let rect = geometry.displayRect
        #expect(Self.close(geometry.normalizedPoint(CGPoint(x: rect.minX, y: rect.minY)), CGPoint(x: 0, y: 0)))
    }

    @Test(arguments: [false, true])
    func `viewPoint inverts normalizedPoint`(flipped: Bool) {
        let geometry = Self.geometry(Self.fullScreen, flipped: flipped)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.8), CGPoint(x: 1, y: 1)] {
            #expect(Self.close(geometry.normalizedPoint(geometry.viewPoint(normalized: point)), point))
        }
    }

    // MARK: - Edges

    @Test func `edges are measured from the display, not the view`() {
        let geometry = Self.geometry(Self.fullScreen)
        let rect = geometry.displayRect
        #expect(geometry.edge(at: CGPoint(x: rect.minX + 5, y: rect.midY)) == .left)
        #expect(geometry.edge(at: CGPoint(x: rect.maxX - 5, y: rect.midY)) == .right)
        #expect(geometry.edge(at: CGPoint(x: rect.midX, y: rect.minY + 5)) == .bottom)
        #expect(geometry.edge(at: CGPoint(x: rect.midX, y: rect.maxY - 5)) == .top)
        #expect(geometry.edge(at: CGPoint(x: rect.midX, y: rect.midY)) == .none)
    }

    @Test func `a point on a bar is at the edge beside it`() {
        let geometry = Self.geometry(Self.fullScreen)
        #expect(geometry.edge(at: CGPoint(x: 10, y: 491)) == .left)
        #expect(geometry.edge(at: CGPoint(x: 1500, y: 491)) == .right)
    }

    @Test func `a flipped view swaps top and bottom`() {
        let geometry = Self.geometry(Self.fullScreen, flipped: true)
        let rect = geometry.displayRect
        #expect(geometry.edge(at: CGPoint(x: rect.midX, y: rect.minY + 5)) == .top)
        #expect(geometry.edge(at: CGPoint(x: rect.midX, y: rect.maxY - 5)) == .bottom)
    }
}
