#if os(macOS) && TAS_UI_PREVIEW
import AppKit
import SwiftUI

struct UIPreviewOptions {
    let width: Int
    let height: Int
    let section: String
    enum InvalidOption: Error { case value(String) }
    init(arguments: [String]) throws {
        func value(_ flag: String) throws -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            guard arguments.indices.contains(index + 1) else { throw InvalidOption.value(flag) }
            return arguments[index + 1]
        }
        func dimension(_ flag: String, fallback: Int) throws -> Int {
            guard let raw = try value(flag) else { return fallback }
            guard let number = Int(raw), (320...4096).contains(number) else { throw InvalidOption.value(flag) }
            return number
        }
        width = try dimension("--ui-width", fallback: 1120)
        height = try dimension("--ui-height", fallback: 760)
        section = try value("--ui-section") ?? (arguments.contains("--ui-preview-sync") ? "sync" : arguments.contains("--ui-preview-versions") ? "versions" : "overview")
        guard ["overview", "files", "deleted", "transfers", "sync", "versions", "settings"].contains(section) else {
            throw InvalidOption.value("--ui-section")
        }
    }
}

/// Isolated, compile-time-only preview of the actual workspace views. No vault
/// is opened and all vault operations remain disabled. Not in release builds.
@MainActor enum UIPreviewRenderer {
    static func renderIfRequested() -> Bool {
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-render"),
              CommandLine.arguments.indices.contains(index + 1) else { return false }
        let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let options: UIPreviewOptions
        do { options = try UIPreviewOptions(arguments: CommandLine.arguments) }
        catch { fputs("Invalid preview options: \(error)\n", stderr); exit(5) }
        let size = NSSize(width: options.width, height: options.height)
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
