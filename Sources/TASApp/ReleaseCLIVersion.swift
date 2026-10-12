#if os(macOS)
import Foundation
import TASCore

/// The GUI release tag does not encode the bundled CLI version. Resolve it from
/// the same tagged source declaration used to create the signed app package.
/// Source metadata is informational only; UpdateInstaller verifies the signed
/// downloaded bundle separately before installing it.
enum ReleaseCLIVersion {
    static func metadataURL(tag: String) -> URL? {
        guard tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        return URL(string: "https://raw.githubusercontent.com/liuchzzyy/tas-macos/\(tag)/Resources/Info.plist")
    }

    static func parse(_ data: Data, guiVersion: String) throws -> String {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let declaredGUI = dictionary["CFBundleShortVersionString"] as? String,
              declaredGUI == guiVersion,
              ReleaseUpdate.isValidVersion(guiVersion),
              let declaredCLI = (dictionary["TASCLIVersion"] as? String)
                ?? (ReleaseUpdate.isVersion(guiVersion, newerThan: "1.2.0") ? nil : guiVersion),
              ReleaseUpdate.isValidVersion(declaredCLI) else {
            throw NSError(domain: "TAS.ReleaseCLIVersion", code: 1)
        }
        return declaredCLI
    }

    static func fetch(tag: String, guiVersion: String) async throws -> String {
        guard let url = metadataURL(tag: tag) else { throw NSError(domain: "TAS.ReleaseCLIVersion", code: 2) }
        var request = URLRequest(url: url)
        request.setValue("TAS-macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "raw.githubusercontent.com",
              data.count <= 64 * 1024 else { throw NSError(domain: "TAS.ReleaseCLIVersion", code: 3) }
        return try parse(data, guiVersion: guiVersion)
    }
}
#endif
