#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TASCore

struct Metric: View {
    @ObservedObject private var preferences = AppPreferences.shared
    let title: String; let value: String; let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(LibraryStyle.helper).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
    }
}
#endif
