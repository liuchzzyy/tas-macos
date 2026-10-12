#if os(macOS)
import SwiftUI

/// Quiet light surfaces shared by the unlocked workspace.
enum TASDesign {
    static let accent = Color(red: 0.15, green: 0.48, blue: 0.40)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let canvas = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let selected = accent.opacity(0.13)
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
