import SwiftUI

// A one-line name that, only when it is actually cut off, shows its full text as a native
// tooltip on hover. Untruncated names show nothing.

private struct FullWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ShownWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TruncatedName: View {
    let text: String
    var font: Font = .body
    var mode: Text.TruncationMode = .middle

    @State private var fullWidth: CGFloat = 0
    @State private var shownWidth: CGFloat = 0

    private var truncated: Bool { fullWidth > shownWidth + 0.5 && shownWidth > 0 }

    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(mode)
            .background(GeometryReader { g in Color.clear.preference(key: ShownWidthKey.self, value: g.size.width) })
            .background(
                // the same text at its natural width, invisible, to learn whether we are cut off
                Text(text).font(font).lineLimit(1).fixedSize().hidden()
                    .background(GeometryReader { g in Color.clear.preference(key: FullWidthKey.self, value: g.size.width) })
                    .frame(width: 0, alignment: .leading)
                    .clipped()
            )
            .onPreferenceChange(FullWidthKey.self) { fullWidth = $0 }
            .onPreferenceChange(ShownWidthKey.self) { shownWidth = $0 }
            // Native expansion tooltip (what Finder and Xcode do for cut-off names): system-sized,
            // system-placed, and only when the name is actually truncated.
            .help(truncated ? text : "")
    }
}
