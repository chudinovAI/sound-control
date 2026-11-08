# Sound Control

Project class: long-lived native macOS project.

## Goal

Control the volume and mute of individual applications from the menu bar. Allow selection of the system output device. The application does not install a virtual driver.

## Acceptance criteria

- [ ] The application builds and launches on macOS 14.2 or later — local `.app` build and launch.
- [ ] The menu displays only applications with active Core Audio output and available output devices — verify starting, stopping, and resuming playback.
- [ ] The level or mute setting is retained in memory when a stream stops and is applied when it resumes — verify transitions from sound to silence and back.
- [ ] Volume and mute changes affect the selected application without changing the volume of others — verify with two audio sources.
- [ ] The output device is changed through system Core Audio — verify with multiple devices.
- [ ] Stopping the application and errors do not leave the intercepted application's sound muted — verify stopping and error scenarios.
- [ ] The interface explains errors and uses the system audio access prompt — verify with permission in a clean state.

## Out of scope

- Automatic music pausing, recording system audio to a file, a virtual audio driver, and publishing the application.

## Constraints

- Swift, SwiftUI, and Core Audio; no third-party dependencies.
- Core Audio process taps require macOS 14.2+ and user permission to capture system audio.
- Audio processing must meet real-time constraints; audio callbacks must not block, perform file I/O, or allocate memory.

## Decisions

- A native menu bar application — quick access without a separate permanent window.
- Process taps instead of a driver — no system virtual device installation is needed. Routing constraints and behavior are verified on a real system.
- Device selection changes the system output; if necessary, the user can restore it in System Settings.

## High-risk areas

- `Sources/SoundControl/AudioEngine.swift`: audio interception, routing, and release; an error can interrupt sound.
- `Sources/SoundControl/AudioDiscovery.swift`: selecting the system output device affects other applications.
