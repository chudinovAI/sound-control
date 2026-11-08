# Sound Control

A native per-app volume mixer for macOS. It uses Core Audio process taps instead of a virtual audio driver. Audio routing still needs further verification with real sound and system permission.

## Build and run

macOS 14.2 or later and Xcode with Swift are required. Building requires an SDK with SwiftUI Liquid Glass support (Xcode 26 or later).

```sh
./scripts/build-app.sh
open 'build/Sound Control.app'
```

The built app is located in the `build` directory inside the project. Automatic startup is disabled. To enable it manually, add `Sound Control.app` under **System Settings → General → Login Items & Extensions → Open at Login**.

A dial icon appears in the menu bar. The panel uses a dark Control Center style: on macOS 26 and later it uses AppKit `NSGlassEffectView` and SwiftUI `glassEffect`; on earlier versions it uses system materials. macOS may request permission to record system audio when processing is first enabled. The app does not save audio to files.

Clicking the icon again should close the panel. Opening and closing have been checked using accessibility actions; a physical mouse click still needs verification.

The list shows applications with active audio output according to Core Audio. An active stream can contain silence; this is not a measurement of audible volume. A helper whose association with an application cannot be confirmed is shown separately. Volume and mute can be changed for available applications in the list; if a process's identity cannot be verified, its row shows “Unavailable”. Settings are stored only while Sound Control is running. Their application after pausing and resuming still needs verification with real audio.

Selecting a device changes the system output. The interface is in English, and the panel is limited to the height of the screen. In normal mode, the application list scrolls; when an error is shown, the message appears above the list and the entire panel content scrolls. If processing cannot be applied, the interface shows “Not applied”. Some audio formats, device configurations, and applications that output audio to a device other than the system output may not be available for processing. The appearance of the latest build and the fallback on macOS 14.2–15 still need visual verification.

The build is signed locally with an ad-hoc signature; notarization and distribution are not configured. If you encounter sound problems, return the application's slider to 100% or quit Sound Control.

## Tests

```sh
swift test
```

The integration test runs `afplay` at zero volume and requires a working macOS audio output. It checks that the process appears and disappears in the model, but does not measure actual sound or verify volume control.
