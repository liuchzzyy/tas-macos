#if os(macOS)
import SwiftUI

/// Pale, consistent surfaces used by the file-management pages.
enum LibraryStyle {
    static let canvas = TASDesign.canvas
    static let surface = TASDesign.surface
    static let hairline = TASDesign.border
    static let pageTitle = Font.system(size: 22, weight: .bold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let helper = Font.system(size: 12)
}

struct LibrarySurface<Content: View>: View {
    @ObservedObject private var preferences = AppPreferences.shared
    var padding: CGFloat = 20
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tasCard(cornerRadius: 14)
    }
}
#endif
