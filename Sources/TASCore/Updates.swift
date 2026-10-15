import Foundation

public struct PasswordPolicy {
    public static func checks(_ password: String) -> [(String, Bool)] {
        let symbols = CharacterSet.punctuationCharacters.union(.symbols)
        return [
            ("至少 12 个字符", password.count >= 12),
            ("包含大写字母", password.unicodeScalars.contains { CharacterSet.uppercaseLetters.contains($0) }),
            ("包含小写字母", password.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }),
            ("包含数字", password.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }),
            ("包含符号", password.unicodeScalars.contains { symbols.contains($0) })
        ]
    }
    public static func isValid(_ password: String) -> Bool { checks(password).allSatisfy(\.1) }
}

/// The embedded CLI is a separate executable and may not have the GUI's version.
public struct SoftwareVersions {
    public let gui: String
    public let cli: String?

    public init(gui: String, cliOutput: String?) {
        self.gui = gui
        guard let cliOutput, cliOutput.hasPrefix("tas "), cliOutput.hasSuffix(" (Swift)") else {
            cli = nil
            return
        }
        let candidate = String(cliOutput.dropFirst(4).dropLast(8))
        cli = ReleaseUpdate.isValidVersion(candidate) ? candidate : nil
    }

    /// Verify independent versions against the signed bundle, not the GUI release tag.
    /// Bundles before GUI 1.2.1 shared the GUI version; newer bundles must
    /// declare TASCLIVersion even when both executables happen to match.
    public func matchesBundleDeclaration(gui expectedGUI: String, cli declaredCLI: String?) -> Bool {
        guard let expectedCLI = declaredCLI ?? (ReleaseUpdate.isVersion(expectedGUI, newerThan: "1.2.0") ? nil : expectedGUI) else { return false }
        return ReleaseUpdate.isValidVersion(expectedGUI) && ReleaseUpdate.isValidVersion(expectedCLI)
            && gui == expectedGUI && cli == expectedCLI
    }

    public func guiNeedsUpdate(to latest: String) -> Bool {
        ReleaseUpdate.isVersion(latest, newerThan: gui)
    }

    public func cliNeedsUpdate(to latest: String) -> Bool {
        guard let cli else { return false }
        return ReleaseUpdate.isVersion(latest, newerThan: cli)
    }

    public func canInstall(release latest: String) -> Bool {
        guard ReleaseUpdate.isValidVersion(gui), cli != nil else { return false }
        // Release tags identify the GUI, not the independently versioned CLI.
        return guiNeedsUpdate(to: latest)
    }

    public func isAhead(of latest: String) -> Bool {
        ReleaseUpdate.isVersion(gui, newerThan: latest)
    }
}

public struct ReleaseUpdate: Sendable {
    public let tag: String
    public let version: String
    public let releaseURL: URL
    public let downloadURL: URL
    public let expectedSHA256: String
    public let expectedSize: Int64
    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int64?
    }
    public init(data: Data) throws {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = String(payload.tag_name.drop(while: { $0 == "v" }))
        guard Self.parts(version) != nil,
              payload.html_url.scheme == "https", payload.html_url.host == "github.com",
              payload.html_url.path == "/liuchzzyy/tas-macos/releases/tag/\(payload.tag_name)",
              let asset = payload.assets.first(where: { $0.name == "TAS-\(version)-arm64.dmg" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com",
              asset.browser_download_url.path == "/liuchzzyy/tas-macos/releases/download/\(payload.tag_name)/\(asset.name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.count == 71, digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let size = asset.size, size > 0
        else { throw NSError(domain: "TAS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "最新 Release 缺少有效版本或 arm64 DMG 下载地址"]) }
        tag = payload.tag_name
        self.version = version
        releaseURL = payload.html_url
        downloadURL = asset.browser_download_url
        expectedSHA256 = String(digest.dropFirst(7)).lowercased()
        expectedSize = size
    }
    public init(tag: String, version: String, releaseURL: URL, downloadURL: URL, expectedSHA256: String, expectedSize: Int64) throws {
        guard Self.isValidVersion(version),
              releaseURL.scheme == "https", releaseURL.host == "github.com",
              downloadURL.scheme == "https", downloadURL.host == "github.com",
              expectedSHA256.count == 64, expectedSHA256.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              expectedSize > 0 else {
            throw NSError(domain: "TAS.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "最新 Release 缺少有效版本或 arm64 DMG 下载地址"])
        }
        self.tag = tag
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.expectedSHA256 = expectedSHA256.lowercased()
        self.expectedSize = expectedSize
    }

    /// Fetch latest release via REST API with rate-limit-immune web fallback.
    public static func fetchLatest() async throws -> ReleaseUpdate {
        if let update = try? await fetchViaREST() {
            return update
        }
        return try await fetchViaWeb()
    }

    private static func fetchViaREST() async throws -> ReleaseUpdate {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/liuchzzyy/tas-macos/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
        if let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"] ?? ProcessInfo.processInfo.environment["GH_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "TAS.Update", code: 2, userInfo: [NSLocalizedDescriptionKey: "GitHub Release 不可用"])
        }
        return try ReleaseUpdate(data: data)
    }

    private static func fetchViaWeb() async throws -> ReleaseUpdate {
        let latestURL = URL(string: "https://github.com/liuchzzyy/tas-macos/releases/latest")!
        var latestReq = URLRequest(url: latestURL)
        latestReq.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
        latestReq.timeoutInterval = 15
        let (_, latestResp) = try await URLSession.shared.data(for: latestReq)
        guard let http = latestResp as? HTTPURLResponse,
              let finalURL = http.url,
              finalURL.host == "github.com",
              finalURL.path.hasPrefix("/liuchzzyy/tas-macos/releases/tag/") else {
            throw NSError(domain: "TAS.Update", code: 3, userInfo: [NSLocalizedDescriptionKey: "GitHub Release 不可用"])
        }
        let tag = finalURL.lastPathComponent
        let version = String(tag.drop(while: { $0 == "v" }))
        guard isValidVersion(version) else {
            throw NSError(domain: "TAS.Update", code: 4, userInfo: [NSLocalizedDescriptionKey: "GitHub Release 不可用"])
        }

        let shaURL = URL(string: "https://github.com/liuchzzyy/tas-macos/releases/download/\(tag)/TAS-\(version)-arm64.dmg.sha256")!
        var shaReq = URLRequest(url: shaURL)
        shaReq.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
        shaReq.timeoutInterval = 15
        let (shaData, shaResp) = try await URLSession.shared.data(for: shaReq)
        guard let shaHttp = shaResp as? HTTPURLResponse, shaHttp.statusCode == 200,
              let shaText = String(data: shaData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let rawHash = shaText.split(separator: " ").first.map(String.init),
              rawHash.count == 64, rawHash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw NSError(domain: "TAS.Update", code: 5, userInfo: [NSLocalizedDescriptionKey: "GitHub Release 不可用"])
        }

        let dmgURL = URL(string: "https://github.com/liuchzzyy/tas-macos/releases/download/\(tag)/TAS-\(version)-arm64.dmg")!
        var dmgReq = URLRequest(url: dmgURL)
        dmgReq.httpMethod = "HEAD"
        dmgReq.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
        dmgReq.timeoutInterval = 15
        let (_, dmgResp) = try await URLSession.shared.data(for: dmgReq)
        guard let dmgHttp = dmgResp as? HTTPURLResponse, dmgHttp.statusCode == 200,
              dmgHttp.expectedContentLength > 0 else {
            throw NSError(domain: "TAS.Update", code: 6, userInfo: [NSLocalizedDescriptionKey: "GitHub Release 不可用"])
        }

        let releaseURL = URL(string: "https://github.com/liuchzzyy/tas-macos/releases/tag/\(tag)")!
        return try ReleaseUpdate(
            tag: tag,
            version: version,
            releaseURL: releaseURL,
            downloadURL: dmgURL,
            expectedSHA256: rawHash.lowercased(),
            expectedSize: dmgHttp.expectedContentLength
        )
    }
    public static func isValidVersion(_ version: String) -> Bool { parts(version) != nil }
    private static func parts(_ version: String) -> [Int]? {
        let values = version.split(separator: ".", omittingEmptySubsequences: false)
        guard values.count == 3 else { return nil }
        let numbers = values.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return numbers.count == 3 ? numbers : nil
    }
    public func isNewer(than installed: String) -> Bool {
        Self.isVersion(version, newerThan: installed)
    }
    public static func isVersion(_ version: String, newerThan installed: String) -> Bool {
        guard let current = Self.parts(installed), let latest = Self.parts(version) else { return false }
        return latest.lexicographicallyPrecedes(current) == false && latest != current
    }
}
