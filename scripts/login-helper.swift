import Foundation
import AppKit

/// Login item only. Do not open the vault or access user credentials here.
let app = Bundle.main.bundleURL
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // TAS.app

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--tas-login-launch"]
configuration.activates = false
var finished = false
var launchError: Error?
NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
    launchError = error
    finished = true
}
// NSWorkspace may deliver its completion on the main run loop; blocking that
// thread with a semaphore would leave a login item stuck until timeout.
let deadline = Date().addingTimeInterval(15)
while !finished && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
guard finished else { fputs("TAS login helper: launch timed out\n", stderr); exit(1) }
if let launchError {
    fputs("TAS login helper: \(launchError.localizedDescription)\n", stderr)
    exit(1)
}
