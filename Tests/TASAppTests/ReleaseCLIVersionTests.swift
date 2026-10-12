import XCTest
import Foundation
@testable import TASApp

final class ReleaseCLIVersionTests: XCTestCase {
    func testParsesIndependentCLIFromVersionedPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>1.2.1</string>
        <key>TASCLIVersion</key><string>1.2.0</string>
        </dict></plist>
        """
        XCTAssertEqual(try ReleaseCLIVersion.parse(Data(xml.utf8), guiVersion: "1.2.1"), "1.2.0")
    }
    func testLegacyBundleFallbackOnlyWhenSignedGUIVersionMatches() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "1.2.0"], format: .xml, options: 0)
        XCTAssertEqual(try ReleaseCLIVersion.parse(data, guiVersion: "1.2.0"), "1.2.0")
        XCTAssertThrowsError(try ReleaseCLIVersion.parse(data, guiVersion: "1.2.1"))
    }
    func testRejectsAbsentCLIInNewReleaseOrInconsistentVersions() throws {
        for dictionary in [
            ["CFBundleShortVersionString": "1.2.1"],
            ["CFBundleShortVersionString": "1.2.0", "TASCLIVersion": "1.2.0"],
            ["CFBundleShortVersionString": "1.2.1", "TASCLIVersion": "invalid"]
        ] {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            XCTAssertThrowsError(try ReleaseCLIVersion.parse(data, guiVersion: "1.2.1"))
        }
        XCTAssertThrowsError(try ReleaseCLIVersion.parse(Data("not a plist".utf8), guiVersion: "1.2.1"))
    }
    func testOnlyTrustedReleaseTagMayFormMetadataURL() {
        XCTAssertEqual(ReleaseCLIVersion.metadataURL(tag: "v1.2.1")?.absoluteString,
                       "https://raw.githubusercontent.com/liuchzzyy/tas-macos/v1.2.1/Resources/Info.plist")
        XCTAssertNil(ReleaseCLIVersion.metadataURL(tag: "../../malicious"))
    }
}
