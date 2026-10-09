import SwiftUI

/// The frame every sheet shares, after the console: a title over a divider,
/// the content, and a divider over the buttons. A sheet's toolbar only lays its
/// buttons along the bottom and shows no title, so the sheet had no head.
struct VPhoneLaunchpadSheet<Content: View, Accessory: View, Actions: View>: View {
    let title: Text
    @ViewBuilder let content: Content
    /// Secondary buttons or status, on the leading side of the footer.
    @ViewBuilder let accessory: Accessory
    /// Cancel and confirm, on the trailing side of the footer.
    @ViewBuilder let actions: Actions

    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.title = title
        self.content = content()
        self.accessory = accessory()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                title
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                accessory
                Spacer(minLength: 16)
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Height

enum VPhoneLaunchpadSheetHeight {
    /// The tallest a form sheet grows, title and buttons included: a
    /// 1440×900 screen keeps the buttons in reach below the menu bar, the
    /// window's toolbar and the Dock.
    static let maximum: CGFloat = 600
    /// The sheet's title and button rows, which stay put while its form scrolls.
    static let chrome: CGFloat = 96
    /// A page control over the form.
    static let pages: CGFloat = 38
}

extension View {
    /// Gives a sheet's form the height of its content, up to `limit`, past
    /// which the form scrolls. Unlike `fixedSize`, a tall page cannot push
    /// the sheet's buttons off the screen.
    func vphoneFittedHeight(limit: CGFloat) -> some View {
        modifier(VPhoneLaunchpadFittedHeight(limit: limit))
    }
}

private struct VPhoneLaunchpadFittedHeight: ViewModifier {
    let limit: CGFloat
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                contentHeight = height
            }
            .frame(height: min(contentHeight ?? limit, limit))
    }
}

/// A segmented control over a sheet's form that shows one page of it at a
/// time, so a sheet with several groups of settings stays short instead of
/// growing past the screen. The sheet resizes to the page, as a settings
/// window does.
struct VPhoneLaunchpadSheetPages<Page: Hashable, Labels: View>: View {
    @Binding var selection: Page
    @ViewBuilder let labels: Labels

    var body: some View {
        Picker(selection: $selection) {
            labels
        } label: {
            EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.top, 16)
    }
}

extension VPhoneLaunchpadSheet where Accessory == EmptyView {
    init(
        _ title: Text,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.init(title, content: content, accessory: { EmptyView() }, actions: actions)
    }
}
