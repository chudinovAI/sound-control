import AppKit
import Combine
import XCTest
@testable import SoundControl

final class InheritedSettingsTests: XCTestCase {
    @MainActor
    func testUnchangedInheritedSettingsDoNotPublish() {
        _ = NSApplication.shared
        let model = MixerModel()
        defer { model.stop() }
        let app = AudioApp(id: "test-app", name: "Test", processIDs: [], processInstances: [], bundleURL: nil, canControl: true, isRunningOutput: true)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        model.setInheritedSettings(for: app.id, level: 0.4, isMuted: true)
        XCTAssertEqual(model.level(for: app), 0.4, accuracy: 0.001)
        XCTAssertTrue(model.isMuted(app))
        XCTAssertEqual(changes, 2)

        changes = 0
        model.setInheritedSettings(for: app.id, level: 0.4, isMuted: true)
        XCTAssertEqual(changes, 0)

        model.setInheritedSettings(for: app.id, level: 1, isMuted: false)
        XCTAssertEqual(model.level(for: app), 1)
        XCTAssertFalse(model.isMuted(app))
        XCTAssertEqual(changes, 2)

        changes = 0
        model.setInheritedSettings(for: app.id, level: 1, isMuted: false)
        XCTAssertEqual(changes, 0)
    }
}
