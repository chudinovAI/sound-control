# Architecture

Initial state: an empty directory, with no previous map. The mixer milestone is under review and awaiting user acceptance.

| Module | Responsibility | Dependencies |
|---|---|---|
| `SoundControlApp.swift` | AppKit status item, dark NSPanel with adaptive height, `NSGlassEffectView` and glass SwiftUI cards; system material on macOS 14.2–15 | AppKit, SwiftUI, `MixerModel` |
| `MixerModel.swift` | Snapshot of devices and applications, user levels, reconciliation of routes and error messages | `AudioDiscovery`, `AudioEngine` |
| `AudioDiscovery.swift` | Active output of process objects, grouping, devices and system output; observation of changes | AppKit, Core Audio |
| `AudioEngine.swift` | Ownership of process taps and private aggregate devices, delivery of the processed signal to the output, and resource cleanup | Core Audio, AudioToolbox |
| `scripts/build-app.sh`, `Resources/Info.plist` | Local build and `.app` description | Swift Package Manager, codesign |

## Contracts and risks

- A process plays directly at 100%; at any other level a tap is used. The mixer's own process is excluded from discovery.
- The UI shows only groups where at least one process has active output according to `kAudioProcessPropertyIsRunningOutput`; this is a stream state, not a measurement of audible amplitude. For routing, the snapshot still includes inactive processes with output devices so that their resumption does not exclude them from an existing tap. A process object that disappears during reading is skipped until the next snapshot; other errors are not suppressed.
- Settings for an application that disappears from the list remain in the model and are applied when its output becomes active again. Settings cannot be specified before the stream first appears. When the group changes, settings are transferred using the PID and process start time if the new group has no choice of its own; an explicit setting on the target group takes precedence even over the mute state of a helper joining it. Transfer is not guaranteed when identity has not been verified. Grouping uses the path to the `.app`, not the bundle ID alone.
- The selection in the interface changes the system output device. Routes are recreated when the configuration changes; user levels are stored only in process memory.
- Unchanged application and device snapshots are not republished to SwiftUI; when transferring settings, the model also does not publish unchanged values. Discovery and route reconciliation continue on the same schedule as before.
- If the audio engine cannot apply a route, the row shows “Not applied”. Formats and layouts that the engine cannot process safely are rejected.
- On first use of taps, macOS requests permission to record system audio. The exact consequences of denying permission on this computer have not been tested; a successful build cannot be taken as verification of those consequences.
- The audio callback must remain real-time-safe. Real-device support, output switching and permission denial require testing; multistream routing does not start atomically.
- When several errors occur simultaneously, only the last message is visible. The actual transparency and dimensions of the latest build, fallback, and automatic application to an application that starts playing audio still require on-device verification.

## Structural comparison

The empty directory has been replaced by a UI, model, discovery, routing and build. The layers separate system operations with side effects from presentation; however, the audio engine and process observation have become more complex because of the Core Audio lifecycle and the handling of different formats.

With the filter change, discovery's responsibility was extended with an activity indicator, the model separates the visible list from the full snapshot used for routing, and the UI only displays the result; no new dependencies or duplicate discovery mechanism were added. Review found a risk in routing only active processes; the corrected version uses the full snapshot. Actual amplitude, tap behavior during pause, and transient errors still need testing; user acceptance is pending.

During cleanup, responsibilities and dependencies remained unchanged compared with this map. The model centralizes the repeated writes of transferred levels and mute settings and skips unchanged values. Transfer rules and routes have not changed; a notification test was added, but a complete transfer with real audio has not been tested. No significant benefit was found in combining system audio helpers with different error contracts.
