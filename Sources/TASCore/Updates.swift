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
        guard let current = Self.parts(installed), let latest = Self.parts(version) else { return false }
        return latest.lexicographicallyPrecedes(current) == false && latest != current
    }
}
