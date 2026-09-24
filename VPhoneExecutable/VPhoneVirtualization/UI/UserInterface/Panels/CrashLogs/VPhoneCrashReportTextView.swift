import AppKit
import SwiftUI

/// A read-only, selectable monospace text view for report text. AppKit's
/// text system lays out only what is visible, so reports of several
/// megabytes open without stalling the window, and lines scroll sideways
/// unless `wrapLines` is on.
struct VPhoneCrashReportTextView: NSViewRepresentable {
    /// Identifies the text; the view replaces its contents only when this changes.
    let identity: String
    let text: String
    let wrapLines: Bool

    final class Coordinator {
        var identity: String?
        var wrapLines: Bool?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context _: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel(VPhoneLocalization.text("Report text"))

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.wrapLines != wrapLines {
            coordinator.wrapLines = wrapLines
            applyWrapping(to: textView, in: scrollView)
        }

        if coordinator.identity != identity {
            coordinator.identity = identity
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.textColor,
            ]
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scroll(.zero)
        }
    }

    // MARK: - Wrapping

    private func applyWrapping(to textView: NSTextView, in scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        scrollView.hasHorizontalScroller = !wrapLines
        textView.isHorizontallyResizable = !wrapLines
        container.widthTracksTextView = wrapLines
        if wrapLines {
            let width = scrollView.contentSize.width
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            container.containerSize = NSSize(
                width: max(width - textView.textContainerInset.width * 2, 0),
                height: CGFloat.greatestFiniteMagnitude,
            )
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.sizeToFit()
    }
}
