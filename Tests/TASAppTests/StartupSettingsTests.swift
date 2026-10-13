import XCTest
@testable import TASApp

final class StartupSettingsTests: XCTestCase {
    @MainActor func testFailedRegistrationDoesNotPersistEnabledState() {
        let suite = "TASStartupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let service = FakeLoginService()
        service.shouldFail = true
        XCTAssertThrowsError(try StartupSettings.setLaunchAtLogin(true, preferences: preferences, service: service))
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertFalse(defaults.bool(forKey: AppPreferences.launchAtLoginKey))
    }
    @MainActor func testRegistrationAndRemovalUseSystemService() throws {
        let suite = "TASStartupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let service = FakeLoginService()
        try StartupSettings.setLaunchAtLogin(true, preferences: preferences, service: service)
        XCTAssertTrue(preferences.launchAtLogin)
        XCTAssertEqual(service.registerCalls, 1)
        try StartupSettings.setLaunchAtLogin(false, preferences: preferences, service: service)
        XCTAssertFalse(preferences.launchAtLogin)
        XCTAssertEqual(service.unregisterCalls, 1)
    }
    @MainActor func testSilentLaunchOnlyForLoginHelperArgument() {
        let suite = "TASStartupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.silentLaunch = true
        XCTAssertFalse(StartupSettings.shouldStartHidden(arguments: ["TAS"], preferences: preferences))
        XCTAssertTrue(StartupSettings.shouldStartHidden(arguments: ["TAS", "--tas-login-launch"], preferences: preferences))
    }
}

private final class FakeLoginService: LoginService {
    var registerCalls = 0
    var unregisterCalls = 0
    var shouldFail = false
    func register() throws {
        registerCalls += 1
        if shouldFail { throw NSError(domain: "test", code: 1) }
    }
    func unregister() throws { unregisterCalls += 1 }
}
