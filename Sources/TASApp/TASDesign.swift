#if os(macOS)
import SwiftUI

/// Quiet light surfaces shared by the unlocked workspace.
enum TASDesign {
    static let accent = Color(red: 0.15, green: 0.48, blue: 0.40)
    static let sidebar = Color(red: 0.956, green: 0.968, blue: 0.970)
    static let canvas = Color(red: 0.978, green: 0.984, blue: 0.984)
    static let surface = Color.white
    static let border = Color(red: 0.87, green: 0.90, blue: 0.91)
    static let selected = Color(red: 0.92, green: 0.966, blue: 0.951)
}

struct TASSectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 13)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

struct TASCard<Content: View>: View {
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
