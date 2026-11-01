import Foundation
@testable import RubyCuts
import Testing

@Suite
struct AppInfoTests {
    @Test func readsVersionAndBuildFromInfoDictionary() {
        let info = AppInfo(
            infoDictionary: ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"],
            rubyVersion: "3.4.9"
        )
        #expect(info.versionAndBuild == "1.2 (34)")
        #expect(info.rubyVersion == "3.4.9")
    }

    @Test func fallsBackToUnknownForMissingKeys() {
        let info = AppInfo(infoDictionary: [:], rubyVersion: "3.4.9")
        #expect(info.versionAndBuild == "Unknown (Unknown)")
    }

    @Test func currentReportsTheEmbeddedRubyVersion() {
        // Reads a compile-time constant, so no VM boot (and no `.serialized`
        // EmbeddedRubyTests nesting) is needed.
        #expect(AppInfo.current.rubyVersion.hasPrefix("3."))
    }

    @Test(arguments: Acknowledgement.all)
    func everyAcknowledgementHasBundledLicenseText(_ acknowledgement: Acknowledgement) {
        let text = acknowledgement.licenseText()
        #expect(text?.isEmpty == false)
    }
}
