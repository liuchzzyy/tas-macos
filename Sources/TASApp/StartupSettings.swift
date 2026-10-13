#if os(macOS)
import Foundation
import ServiceManagement

protocol LoginService {
    func register() throws
    func unregister() throws
}

/// A signed login-item helper launches the main app with a private launch marker.
/// The user's normal Finder/Dock launches never carry this argument.
private struct SystemLoginService: LoginService {
    private let service = SMAppService.loginItem(identifier: "com.liuchzzyy.tas.login-helper")
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor enum StartupSettings {
    static let loginArgument = "--tas-login-launch"
    static func shouldStartHidden(arguments: [String], preferences: AppPreferences) -> Bool {
        preferences.silentLaunch && arguments.contains(loginArgument)
    }
    static func shouldQuitAfterLastWindow(preferences: AppPreferences) -> Bool {
        preferences.closeBehavior == .quit
    }
    /// Only report enabled after registration succeeds; failed registration does
    /// not leave a misleading preference or partial local autostart entry.
    static func setLaunchAtLogin(_ enabled: Bool, preferences: AppPreferences,
                                 service: LoginService = SystemLoginService()) throws {
        if enabled { try service.register() } else { try service.unregister() }
        preferences.launchAtLogin = enabled
    }
    static var systemEnabled: Bool {
        SMAppService.loginItem(identifier: "com.liuchzzyy.tas.login-helper").status == .enabled
    }
}
#endif
