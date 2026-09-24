import SwiftUI

/// The guest screenshot with every loaded frame outlined. Click selects the
/// smallest frame under the pointer; double-click taps that point on the guest.
struct VPhoneUIInspectorScreenView: View {
    let model: VPhoneUIInspectorModel

    var body: some View {
        if let size = model.pointSize {
            screen(size: size)
                .aspectRatio(size, contentMode: .fit)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.activity == .capturing {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VPhonePanelEmptyState(
                title: "No Screenshot",
                systemImage: "iphone",
                message: "Choose Refresh to capture the guest screen.",
            )
        }
    }

    // MARK: - Screen

    private func screen(size: CGSize) -> some View {
        ZStack {
            if let screenshot = model.screenshot {
                Image(nsImage: screenshot)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            GeometryReader { geometry in
                // Guest points to view points. The aspect ratio is fixed, so
                // one factor serves both axes.
                let scale = geometry.size.width / size.width
                overlay(scale: scale)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, coordinateSpace: .local) { location in
                        let point = CGPoint(x: location.x / scale, y: location.y / scale)
                        model.select(at: point)
                        Task { await model.tap(at: point) }
                    }
                    .simultaneousGesture(
                        SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                            model.select(at: CGPoint(x: value.location.x / scale, y: value.location.y / scale))
                        },
                    )
            }
        }
        .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .help("Click to select the element under the pointer. Double-click to tap there in the guest.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guest screenshot")
    }

    private func overlay(scale: CGFloat) -> some View {
        let overlays = model.overlays
        let selected = model.selectedFrame
        let outline: Color = model.source == .accessibility ? .blue : .green
        return Canvas { context, _ in
            for item in overlays {
                let rect = scaled(item.frame, scale)
                guard rect.width > 0, rect.height > 0 else { continue }
                context.stroke(Path(rect), with: .color(outline.opacity(0.75)), lineWidth: 1)
            }
            if let selected {
                let rect = scaled(selected, scale)
                context.fill(Path(rect), with: .color(Color.accentColor.opacity(0.3)))
                context.stroke(Path(rect), with: .color(Color.accentColor), lineWidth: 2)
            }
        }
    }

    private func scaled(_ rect: CGRect, _ scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .insetBy(dx: 0.5, dy: 0.5)
    }
}
