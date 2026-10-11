#!/usr/bin/env swift
// Native accessibility smoke: no passwords, network, or existing vaults.
import Foundation
import AppKit
import ApplicationServices

struct SmokeFailure: Error, CustomStringConvertible { let description: String }
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func descendants(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 16 else { return [] }
    let children = attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []
    return [root] + children.flatMap { descendants($0, depth: depth + 1) }
}
func run() throws {
    guard CommandLine.arguments.count == 2 else { throw SmokeFailure(description: "Usage: swift scripts/smoke-history-gui.swift /path/to/TASDesktop") }
    guard AXIsProcessTrusted() else { throw SmokeFailure(description: "BLOCKED: terminal requires existing Accessibility permission; no permissions requested or changed") }
    let scratch = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch", isDirectory: true)
    let temporary = scratch.appendingPathComponent("tas-history-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
    process.environment = ProcessInfo.processInfo.environment.merging(["TAS_DATA_DIR": temporary.path, "TMPDIR": temporary.path]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    let app = AXUIElementCreateApplication(process.processIdentifier)
    let deadline = Date().addingTimeInterval(20)
    var menu: AXUIElement?
    while process.isRunning && Date() < deadline {
        if let value = attribute(app, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            menu = unsafeBitCast(value, to: AXUIElement.self)
            if descendants(menu!).contains(where: { (attribute($0, kAXTitleAttribute) as? String) == "文件库" }) { break }
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard let menu else { throw SmokeFailure(description: "FAIL: native menu bar unavailable") }
    let items = descendants(menu)
    for title in ["版本历史…", "恢复自动同步…"] {
        guard let item = items.first(where: { (attribute($0, kAXTitleAttribute) as? String) == title }) else {
            let titles = items.compactMap { attribute($0, kAXTitleAttribute) as? String }
            throw SmokeFailure(description: "FAIL: missing selected-file action ‘\(title)’; observed menu titles: \(titles)")
        }
        guard (attribute(item, kAXEnabledAttribute) as? Bool) == false else { throw SmokeFailure(description: "FAIL: ‘\(title)’ must be disabled while locked") }
        print("PASS: native menu ‘\(title)’ exists and is disabled while locked")
    }
    print("PASS: isolated locked-state accessibility smoke; unlocked/history workflows are not exercised")
}
do { try run() } catch { fputs("\(error)\n", stderr); exit(1) }
