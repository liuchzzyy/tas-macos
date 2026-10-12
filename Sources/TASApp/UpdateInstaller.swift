#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import TASCore

struct PreparedUpdate {
    let app: URL
    let helper: URL
}

enum UpdateInstaller {
    struct Failure: LocalizedError {
        let reason: String
        init(_ reason: String) { self.reason = reason }
        var errorDescription: String? { reason }
    }

    static func prepare(_ release: ReleaseUpdate, helper: URL) async throws -> PreparedUpdate {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("tas-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var handedOff = false
        defer { if !handedOff { try? fm.removeItem(at: directory) } }

        var request = URLRequest(url: release.downloadURL)
        request.timeoutInterval = 60
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw Failure(L10n.tr("下载失败；请检查网络及 GitHub Release 是否公开"))
        }
        let dmg = directory.appendingPathComponent(release.downloadURL.lastPathComponent)
        try fm.moveItem(at: temporary, to: dmg)
        let values = try dmg.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == release.expectedSize else { throw Failure(L10n.tr("下载文件大小与 Release 不符")) }
        let digest = SHA256.hash(data: try Data(contentsOf: dmg, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == release.expectedSHA256 else { throw Failure(L10n.tr("SHA-256 校验失败，更新已取消")) }

        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, dmg.path],
                error: L10n.tr("无法挂载已校验的 DMG"))
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path], error: L10n.tr("卸载 DMG 失败")) }
        let candidate = mount.appendingPathComponent("TAS.app", isDirectory: true)
        let staged = directory.appendingPathComponent("TAS.app", isDirectory: true)
        try run("/usr/bin/ditto", [candidate.path, staged.path], error: L10n.tr("无法读取 DMG 内的 TAS.app"))
        guard let bundle = Bundle(url: staged),
              bundle.bundleIdentifier == "com.liuchzzyy.tas",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw Failure(L10n.tr("下载的应用标识或版本不符"))
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], error: L10n.tr("下载的应用签名校验失败"))
        let stagedCLI = staged.appendingPathComponent("Contents/Helpers/tas")
        let stagedVersions = SoftwareVersions(gui: release.version, cliOutput: EmbeddedCLIVersionProbe.read(from: stagedCLI))
        let declaredCLI = bundle.object(forInfoDictionaryKey: "TASCLIVersion") as? String
        guard stagedVersions.matchesBundleDeclaration(gui: release.version, cli: declaredCLI) else {
            throw Failure(L10n.tr("下载的 CLI 版本与应用包声明不符"))
        }
        let stagedHelper = directory.appendingPathComponent("TASUpdater")
        try fm.copyItem(at: helper, to: stagedHelper)
        handedOff = true
        return PreparedUpdate(app: staged, helper: stagedHelper)
    }

    static var resultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TAS/update-result.txt")
    }

    private static func run(_ executable: String, _ arguments: [String], error: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(error) }
    }
}
#endif
