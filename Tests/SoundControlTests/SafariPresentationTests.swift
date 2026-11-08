import AppKit
import Foundation
import XCTest
@testable import SoundControl

final class SafariPresentationTests: XCTestCase {
    private let safari = URL(fileURLWithPath: "/Applications/Safari.app")
    private let otherSafari = URL(fileURLWithPath: "/Other/Safari.app")

    func testRecognizedSafariProcessUsesTheUniqueSafariIcon() {
        let result = AudioDiscovery.safariPresentationURL(
            processName: "Safari Graphics and Media",
            bundleID: "com.apple.WebKit.GPU",
            candidates: [safari]
        )
        XCTAssertEqual(result, safari.resolvingSymlinksInPath().standardizedFileURL)
    }

    func testOtherWebKitHostsAndMissingInformationAreNotRelabeled() {
        XCTAssertNil(AudioDiscovery.safariPresentationURL(processName: "Other Graphics and Media", bundleID: "com.apple.WebKit.GPU", candidates: [safari]))
        XCTAssertNil(AudioDiscovery.safariPresentationURL(processName: "Safari Graphics and Media", bundleID: "com.apple.WebKit.WebContent", candidates: [safari]))
        XCTAssertNil(AudioDiscovery.safariPresentationURL(processName: nil, bundleID: "com.apple.WebKit.GPU", candidates: [safari]))
        XCTAssertNil(AudioDiscovery.safariPresentationURL(processName: "Safari Graphics and Media", bundleID: "com.apple.WebKit.GPU", candidates: []))
    }

    func testAmbiguousSafariInstallationsAreNotRelabeled() {
        XCTAssertNil(AudioDiscovery.safariPresentationURL(
            processName: "Safari Graphics and Media",
            bundleID: "com.apple.WebKit.GPU",
            candidates: [safari, otherSafari]
        ))
    }

    @MainActor
    func testLiveSafariProcessRemainsASeparateGroupWhenAvailable() throws {
        let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
            .filter { !$0.isTerminated }.compactMap(\.bundleURL)
        guard let expectedURL = AudioDiscovery.safariPresentationURL(
            processName: "Safari Graphics and Media", bundleID: "com.apple.WebKit.GPU", candidates: candidates
        ) else {
            throw XCTSkip("No unambiguous running Safari installation is available")
        }
        let processes = NSWorkspace.shared.runningApplications.filter { process in
            let paths = [process.bundleURL, process.executableURL].compactMap { $0 }
            return process.localizedName == "Safari Graphics and Media"
                && process.bundleIdentifier == "com.apple.WebKit.GPU"
                && !paths.contains { $0.pathComponents.contains { $0.lowercased().hasSuffix(".app") } }
        }
        _ = NSApplication.shared
        let model = MixerModel()
        defer { model.stop() }
        guard let match = processes.compactMap({ process in
            model.apps.first { app in app.processInstances.contains { $0.hasPrefix("\(process.processIdentifier):") } }
        }).first else {
            throw XCTSkip("No active, verifiable Safari audio process is available")
        }
        XCTAssertTrue(match.id.hasPrefix("pid:"), "Presentation must not merge the process into Safari's route")
        XCTAssertTrue(match.name.hasSuffix(" Audio"))
        XCTAssertEqual(match.bundleURL, expectedURL)
        XCTAssertFalse(match.processIDs.isEmpty)
    }
}
