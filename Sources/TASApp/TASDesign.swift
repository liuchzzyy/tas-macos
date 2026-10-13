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
    /// Cards must read as raised. The system colors resolve to the same value as
    /// the canvas in both appearances (white/white in light, 0.118/0.118 in dark),
    /// so a shared system color would leave surfaces visible only by their border.
    static let surface = Color(nsColor: NSColor(name: "TASCardSurface") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.165, green: 0.169, blue: 0.169, alpha: 1)
            : NSColor.white
    })
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
                // Tinted near-white page so white cards keep a readable edge.
                LinearGradient(colors: [Color(red: 0.945, green: 0.966, blue: 0.956),
                                        Color(red: 0.984, green: 0.992, blue: 0.988)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                TASDesign.canvas
            }
        }
    }
}

/// Shared card elevation: appearance-aware surface, hairline border and a soft
/// shadow that only darkens what sits below the card.
struct TASElevation: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(TASDesign.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(TASDesign.border))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.07),
                    radius: 7, x: 0, y: 2)
    }
}

extension View {
    func tasCanvas() -> some View { modifier(TASCanvas()) }
    func tasCard(cornerRadius: CGFloat = 15) -> some View { modifier(TASElevation(cornerRadius: cornerRadius)) }
}

struct TASSectionLabel: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 19)
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
            .padding(18)
            .tasCard()
    }
}
#endif
