#if os(macOS) && TAS_UI_PREVIEW
import AppKit
import SwiftUI

/// Isolated, compile-time-only preview of the actual workspace views. No vault
/// is opened and all vault operations remain disabled. Not in release builds.
@MainActor enum UIPreviewRenderer {
    static func renderIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-render"),
              CommandLine.arguments.indices.contains(index + 1) else { return false }
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let size = NSSize(width: 1120, height: 760)
        let root = RootView().environmentObject(AppModel())
            .frame(width: size.width, height: size.height)
            .tint(TASDesign.accent)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(2) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            do {
                try data.write(to: destination)
                print("Rendered actual SwiftUI workspace (isolated component preview): \(destination.path)")
                window.orderOut(nil)
                exit(0)
            } catch { fputs("Preview rendering failed: \(error)\n", stderr); exit(4) }
        }
        return true
    }
}
#endif
