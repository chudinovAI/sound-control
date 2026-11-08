# Plan

## Milestone: application mixer

The panel build and launch have been verified on the current Mac; the separate glass container requires another visual check. A test `afplay` was found, macOS requested permission when mute was applied, and after confirmation the interface indicated that sound was muted, then showed 100% after the level was restored. Actual sound amplitude and operation on macOS 14.2 were not separately tested.
1. Control icon and AppKit panel: transparent `NSGlassEffectView` on macOS 26+, `NSVisualEffectView` on older systems. A compact English interface 320 pt wide, adaptive height, and an output menu without highlighting have been built; the final independent static review found no significant issues. Visual verification of the new build awaits an application restart and screen access. [partial]
2. Core Audio discovery and system output selection — local discovery smoke test for processes and devices; verification of output switching is still required. [partial]
3. Process taps, volume control, and sound restoration — the system prompt and UI transition between mute and 100% were verified with a test source; actual signal level, two sources, permission denial, device switching, and device disconnection were not tested. [partial, high-risk]
4. Independent review: review0–review4 completed; after user permission, the findings from review2 and review3 were fixed. Review4 identified remaining limitations in refining helper-process attribution and displaying simultaneous observation errors. [incomplete, high-risk]
5. Structural review: compare the map with the original empty directory, note complexity and limitations, update ARCHITECTURE.md, and present it to the user for acceptance. [map recorded, acceptance pending, high-risk]

## Running applications and compact panel

- The header was removed; the list is supplemented with running applications with a regular interface and user menu bar applications. Installed but closed applications are not displayed.
- Volume and mute for an application without an audio process are retained in memory until a process is discovered. The association of a reconfigurable helper is stored by PID and start time; an explicit choice for the target group takes precedence.
- The build passes. A discovery smoke test found all 9 running regular applications; a check of Finder without a stream confirmed retention of 42%, mute, and unmute.
- The previous build showed 19 applications without a header, but the panel was too short. The height calculation was fixed; visual verification of the latest build awaits permission to control the screen and a process restart.
- Automatic application of settings when playback starts and transfer of mute between groups have not been tested with real audio. Routes are recreated non-atomically.
- By user decision, grouping solely by bundle ID was removed; applications with different paths are not combined. The latest independent static review of settings migration found no significant errors; testing with real audio remains outstanding.
- The design was reworked to match Control Center: a dark panel and system glass for cards on macOS 26+, light text and sliders. The new build awaits visual verification: the screen-control request remained unanswered.
- A repeated press of the icon is handled as a panel toggle; the global outside-click handler excludes the icon area. Verification of event order in the GUI awaits a restart.
- The panel layout was recalculated with 12 pt top and bottom margins; the regular list scrolls without a nested area. When an error occurs, the message appears above the list as chosen by the user, and the panel contents have a single scroll area; on a very short screen, a single shared scroll area is also used.
- The new build passes. Verification of actual smoothness and spacing awaits a restart: the screen-control request remained unanswered.
- A repeated left click on the icon while the panel is open is intercepted before the button action. The build passes, and an independent static review found no issues. After an agreed restart, the new application opened and closed with two AXPress actions on the icon; a physical click was not tested, and the screen-control request remained unanswered.
- Measurement with no application changes over 8.2 s: before optimization, 4 identical application publications and 4 device publications, 8 model notifications; after comparing snapshots — 0, 0, and 0 respectively. The build passes; the change was checked by an independent static review. Scrolling smoothness and CPU usage were not measured; there is no automated CI budget.

### Active output only

- Instead of all running applications, the UI shows groups with active output IO; this is not a measurement of an audible signal. It is no longer possible to configure an application before its first stream.
- The full snapshot of processes with output devices, including inactive ones, is retained for routing; the existing risk of non-atomic route recreation remains. A process that disappears during reading with `kAudioHardwareBadObjectError` is skipped until the next snapshot.
- The `.app` build passed, and an integration test of the model with a quiet `afplay` confirmed that an active process appeared and disappeared after completion. Independent review1 found no significant new issues. The running instance was not restarted; the latest build's panel, pause/resume, mute, amplitude, and playback during failures have not yet been tested.
- The structural map and changed contract are recorded in ARCHITECTURE.md; user acceptance is pending.

### Remaining review4 findings

- With incomplete initial attribution, a helper may remain a separate row instead of joining its application's group.
- When observation and route errors occur simultaneously, the interface shows the latest message rather than all errors.

### Cleanup and source preparation for GitHub

- The audit found no demonstrably dead code in the audio engine; its defensive checks were retained. Repeated publications of unchanged transferred settings were removed; the test directly checks settings writes and notifications, but not the full transfer and routes. The effect on CPU was not measured.
- README was corrected for the current filter; local build artifacts remain excluded from Git. Hosting the source code was approved by the user separately from publishing the finished application.
- The audit noted potential accumulation of process-owner identifiers and quadratic listener reconciliation; their impact has not been measured, and safe cleanup requires checking lifecycles and routes.

Actual capture requires system permission from the user. Publishing the finished application and installing a driver are out of scope.
