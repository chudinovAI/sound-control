import AppKit
import Combine
import CoreAudio

@MainActor
final class MixerModel: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var outputDevice: AudioObjectID = 0
    @Published private(set) var errorMessage: String?
    @Published private var levels: [String: Float] = [:]
    @Published private var muted: Set<String> = []
    @Published private(set) var pending: Set<String> = []

    private let engine = AudioEngine()
    private var applied: [String: Applied] = [:]
    private var processOwners: [String: String] = [:]
    private var explicitSettings: Set<String> = []
    private var timer: AnyCancellable?
    private var termination: AnyCancellable?
    private var observer: AudioDiscoveryObserver?

    private struct Applied: Equatable {
        let processes: [AudioObjectID]
        let gain: Float
        let output: AudioObjectID
    }

    init() {
        engine.onRouteFailure = { [weak self] id, message in
            guard let self else { return }
            self.applied.removeValue(forKey: id)
            self.pending.insert(id)
            self.errorMessage = message
        }
        ensureObserver()
        refresh()
        timer = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }
    }

    func level(for app: AudioApp) -> Float { levels[app.id] ?? 1 }
    func isMuted(_ app: AudioApp) -> Bool { muted.contains(app.id) }

    func setLevel(_ value: Float, for app: AudioApp) {
        explicitSettings.insert(app.id)
        levels[app.id] = min(1, max(0, value))
        if value > 0 { muted.remove(app.id) }
        apply(app)
    }

    func toggleMute(_ app: AudioApp) {
        explicitSettings.insert(app.id)
        levels[app.id] = level(for: app)
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        apply(app)
    }

    func selectOutput(_ id: AudioObjectID) {
        do {
            try AudioDiscovery.setDefaultOutputDevice(id)
            refresh()
        } catch {
            errorMessage = "Could not select the output device: \(error.localizedDescription)"
        }
    }

    func dismissError() { errorMessage = nil }

    // Preserve the existence of a setting even when its value is the default.
    func setInheritedSettings(for id: String, level: Float, isMuted: Bool) {
        if levels[id] != level { levels[id] = level }
        if isMuted != muted.contains(id) {
            if isMuted { muted.insert(id) } else { muted.remove(id) }
        }
    }

    private func ensureObserver() {
        guard observer == nil else { return }
        do {
            observer = try AudioDiscoveryObserver { [weak self] in self?.refresh() }
        } catch {
            errorMessage = "Could not observe audio processes: \(error.localizedDescription)"
        }
    }


    func stop() {
        timer?.cancel()
        observer?.stop()
        engine.stopAll()
        applied.removeAll()
    }

    private func refresh() {
        do {
            var outputError: Error?
            let currentOutput: AudioObjectID
            do {
                currentOutput = try AudioDiscovery.defaultOutputDevice()
            } catch {
                currentOutput = AudioObjectID(kAudioObjectUnknown)
                outputError = error
            }
            if outputDevice != currentOutput {
                engine.stopAll()
                pending.formUnion(applied.keys)
                applied.removeAll()
                outputDevice = currentOutput
            }
            ensureObserver()
            do {
                try observer?.refreshProcesses()
            } catch {
                errorMessage = "Could not observe audio processes: \(error.localizedDescription)"
            }
            let currentApps = try AudioDiscovery.applications()
            let currentDevices = try AudioDiscovery.outputDevices()
            let previousLevels = levels
            let previousMuted = muted
            for app in currentApps where !explicitSettings.contains(app.id) && !app.processInstances.isEmpty {
                let former = Set(app.processInstances.compactMap { processOwners[$0] })
                    .filter { previousLevels[$0] != nil || previousMuted.contains($0) }
                if let source = former.filter({ previousMuted.contains($0) }).min(by: { (previousLevels[$0] ?? 1) < (previousLevels[$1] ?? 1) }) {
                    setInheritedSettings(for: app.id, level: previousLevels[source] ?? 1, isMuted: true)
                } else if let source = former.min(by: { (previousLevels[$0] ?? 1) < (previousLevels[$1] ?? 1) }) {
                    setInheritedSettings(for: app.id, level: previousLevels[source] ?? 1, isMuted: false)
                }
            }
            let currentProcesses = Dictionary(uniqueKeysWithValues: currentApps.map { ($0.id, $0.processIDs.sorted()) })
            for (id, state) in applied where currentProcesses[id] != state.processes || (levels[id] == nil && !muted.contains(id)) {
                engine.remove(appID: id)
                applied.removeValue(forKey: id)
            }
            let visibleApps = currentApps.filter(\.isRunningOutput)
            if apps != visibleApps { apps = visibleApps }
            if devices != currentDevices { devices = currentDevices }
            if let outputError {
                errorMessage = "Could not read audio output: \(outputError.localizedDescription)"
            }
            for app in currentApps where levels[app.id] != nil || muted.contains(app.id) {
                apply(app)
            }
        } catch {
            errorMessage = "Could not read audio state: \(error.localizedDescription)"
        }
    }

    private func apply(_ app: AudioApp) {
        let gain: Float = muted.contains(app.id) ? 0 : level(for: app)
        for instance in app.processInstances {
            processOwners[instance] = app.id
        }
        if app.processIDs.isEmpty {
            engine.remove(appID: app.id)
            applied.removeValue(forKey: app.id)
            pending.remove(app.id)
            return
        }
        let state = Applied(processes: app.processIDs.sorted(), gain: gain, output: outputDevice)
        do {
            if gain != 1 {
                let outputs = try AudioDiscovery.processOutputDevices(state.processes)
                guard !outputs.isEmpty, outputs == [outputDevice] else {
                    throw MixerError.unsupportedRouting
                }
            }
            guard applied[app.id] != state else { return }
            try engine.setGain(appID: app.id, processIDs: state.processes, gain: gain, outputDeviceID: outputDevice)
            applied[app.id] = state
            pending.remove(app.id)
        } catch {
            engine.remove(appID: app.id)
            applied.removeValue(forKey: app.id)
            pending.insert(app.id)
            errorMessage = "Could not change the volume for \(app.name): \(error.localizedDescription)"
        }
    }
}

private enum MixerError: LocalizedError {
    case unsupportedRouting

    var errorDescription: String? {
        "The app uses a different or unknown output device; its route was not changed."
    }
}
