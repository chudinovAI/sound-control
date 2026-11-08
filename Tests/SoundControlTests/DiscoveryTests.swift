import AppKit
import XCTest
@testable import SoundControl

final class DiscoveryTests: XCTestCase {
    @MainActor
    func testSilentPlayerAppearsAndDisappearsInMixer() throws {
        _ = NSApplication.shared
        let model = MixerModel()
        defer { model.stop() }

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        // Zero gain avoids audible playback while still opening output IO.
        player.arguments = ["-v", "0", "-r", "0.1", "/System/Library/Sounds/Submarine.aiff"]
        try player.run()
        defer {
            if player.isRunning { player.terminate() }
            player.waitUntilExit()
        }
        let instancePrefix = "\(player.processIdentifier):"
        func visible() -> Bool {
            model.apps.contains { app in
                app.processInstances.contains { $0.hasPrefix(instancePrefix) }
            }
        }
        func waitFor(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if condition() { return true }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return condition()
        }
        XCTAssertTrue(waitFor { visible() }, "Active output must appear in the mixer")
        XCTAssertTrue(model.apps.allSatisfy(\.isRunningOutput), "Inactive groups must not be visible")
        player.terminate()
        player.waitUntilExit()
        XCTAssertTrue(waitFor { !visible() }, "A stopped process must disappear from the mixer")
    }
}
