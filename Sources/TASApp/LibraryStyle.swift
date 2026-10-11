#if os(macOS)
import SwiftUI

/// Pale, consistent surfaces used by the file-management pages.
enum LibraryStyle {
    static let canvas = TASDesign.canvas
    static let surface = TASDesign.canvas
    static let hairline = TASDesign.border
    static let pageTitle = Font.system(size: 29, weight: .bold)
    static let sectionTitle = Font.system(size: 20, weight: .semibold)
    static let body = Font.system(size: 14)
    static let helper = Font.system(size: 13)
}

struct LibrarySurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LibraryStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(LibraryStyle.hairline) }
    }
}
#endif
