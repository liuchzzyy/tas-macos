import Foundation
import AppKit
import CoreGraphics

let executable = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("tas-gui-smoke-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let process = Process()
process.executableURL = executable
process.environment = ProcessInfo.processInfo.environment.merging(["TAS_DATA_DIR": temporary.path]) { _, new in new }
let log = output.appendingPathComponent("gui-smoke.log")
FileManager.default.createFile(atPath: log.path, contents: nil)
let handle = try FileHandle(forWritingTo: log)
process.standardOutput = handle; process.standardError = handle
let start = Date()
try process.run()
defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? handle.close() }
var window: [String: Any]?
while Date().timeIntervalSince(start) < 20 && process.isRunning {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    window = windows.first { row in
        guard (row[kCGWindowOwnerPID as String] as? Int32) == process.processIdentifier,
              (row[kCGWindowLayer as String] as? Int) == 0,
              let bounds = row[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return false }
        return width >= 800 && height >= 500
    }
    if window != nil { break }
    Thread.sleep(forTimeInterval: 0.05)
}
guard let window, let id = window[kCGWindowNumber as String] as? Int else {
    fputs("Native application did not create a visible window.\n", stderr)
    if let contents = try? String(contentsOf: log, encoding: .utf8) { fputs(contents, stderr) }
    exit(1)
}
let elapsed = Date().timeIntervalSince(start)
let report = String(format: "PASS: native SwiftUI window visible in %.3f seconds (CI host; not a controlled cold-start benchmark)\n", elapsed)
print(report)
try report.write(to: output.appendingPathComponent("gui-launch-report.txt"), atomically: true, encoding: .utf8)
// Screenshot availability depends on the runner's screen-recording permissions.
Thread.sleep(forTimeInterval: 0.5)
let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-l", String(id), output.appendingPathComponent("TAS-native-window.png").path]
try? capture.run(); capture.waitUntilExit()
