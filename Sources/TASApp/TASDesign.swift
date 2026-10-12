#if os(macOS)
import SwiftUI

/// Adaptive, layered workspace colors: light canvas is no longer system gray.
enum TASDesign {
    static let accent = Color(nsColor: NSColor(name: "TASBrandGreen") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.36, green: 0.76, blue: 0.63, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.48, blue: 0.40, alpha: 1)
    })
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let border = Color(nsColor: NSColor(name: "TASCardBorder") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.20) : NSColor(white: 0, alpha: 0.12)
    })
    static let dropBorder = accent.opacity(0.40)
    static let selected = accent.opacity(0.13)
    static let dropZone = accent.opacity(0.055)
}

struct TASCanvas: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.background {
            if colorScheme == .light {
                LinearGradient(colors: [Color(red: 0.97, green: 0.985, blue: 0.98), .white],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                TASDesign.canvas
            }
        }
    }
}

extension View {
    func tasCanvas() -> some View { modifier(TASCanvas()) }
}

struct TASSectionLabel: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

struct TASCard<Content: View>: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(TASDesign.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(TASDesign.border))
    }
}
#endif
