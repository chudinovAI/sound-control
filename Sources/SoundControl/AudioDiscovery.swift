import AppKit
import CoreAudio
import Darwin.libproc
import Foundation

/// A group of Core Audio process objects belonging to the same application.
/// `processIDs` contains AudioObjectIDs, not Unix process IDs.
struct AudioApp: Identifiable, Equatable {
    let id: String
    let name: String
    let processIDs: [AudioObjectID]
    let processInstances: [String]
    let bundleURL: URL?
    let canControl: Bool
    let isRunningOutput: Bool
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
}

/// A Core Audio failure, including the object and property involved.
struct AudioDiscoveryError: LocalizedError {
    let operation: String
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed for audio object \(objectID), property \(selector) (OSStatus \(status))."
    }
}

/// Takes snapshots of the Core Audio process and device lists.
///
/// A process object that disappears while being read is skipped; other failures
/// are reported. App attribution is best effort: embedded helpers are grouped by
/// their enclosing .app. A bundle ID alone is not proof of membership. The
/// snapshot includes idle processes with output devices for stable routing;
/// activity describes running output IO, not signal level.
/// Device IDs and process object IDs are valid only while those objects exist.
enum AudioDiscovery {
    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private struct ApplicationGroup {
        let name: String
        var processIDs: [AudioObjectID]
        var processInstances: [String]
        let bundleURL: URL?
        var canControl: Bool
        var isRunningOutput: Bool
    }

    static func applications() throws -> [AudioApp] {
        let processObjects = try objectIDs(
            object: systemObject,
            selector: kAudioHardwarePropertyProcessObjectList
        )
        var groups: [String: ApplicationGroup] = [:]

        for processObject in processObjects {
            do {
                let pid: pid_t = try scalar(
                    object: processObject,
                    selector: kAudioProcessPropertyPID,
                    initial: 0
                )
                guard pid != getpid() else { continue }

                let runningOutput: UInt32 = try scalar(
                    object: processObject,
                    selector: kAudioProcessPropertyIsRunningOutput,
                    initial: 0
                )
                if runningOutput == 0 {
                    let devices = try objectIDs(
                        object: processObject,
                        selector: kAudioProcessPropertyDevices,
                        scope: kAudioObjectPropertyScopeOutput
                    )
                    if devices.isEmpty { continue }
                }
                let start = processStart(pid)

                let bundleID = try string(
                    object: processObject,
                    selector: kAudioProcessPropertyBundleID
                )
                let runningApp = NSRunningApplication(processIdentifier: pid)
                let executableURL = processExecutableURL(pid)
                let appURL = enclosingApplication(runningApp?.bundleURL)
                    ?? enclosingApplication(executableURL)

                let bundle = appURL.flatMap(Bundle.init(url:))
                let id: String
                if start == nil {
                    id = "unverified:\(pid):\(processObject)"
                } else if let appURL {
                    id = "app:\(appURL.resolvingSymlinksInPath().standardizedFileURL.path)"
                } else {
                    id = "pid:\(pid):\(start!)"
                }
                let fallbackName = executableURL?.lastPathComponent
                    ?? (bundleID?.isEmpty == false ? bundleID : nil)
                    ?? "Process \(pid)"
                let safariURL: URL?
                if appURL == nil, bundleID == "com.apple.WebKit.GPU", runningApp?.localizedName == "Safari Graphics and Media" {
                    let candidates = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
                        .filter { !$0.isTerminated }
                        .compactMap(\.bundleURL)
                    safariURL = safariPresentationURL(processName: runningApp?.localizedName, bundleID: bundleID, candidates: candidates)
                } else {
                    safariURL = nil
                }
                let name = safariURL.map { "\(bundleName(Bundle(url: $0)) ?? "Safari") Audio" }
                    ?? bundleName(bundle)
                    ?? appURL?.deletingPathExtension().lastPathComponent
                    ?? runningApp?.localizedName
                    ?? fallbackName

                groups[id, default: ApplicationGroup(name: name, processIDs: [], processInstances: [], bundleURL: safariURL ?? appURL, canControl: start != nil, isRunningOutput: false)]
                    .processIDs.append(processObject)
                if runningOutput != 0 { groups[id]?.isRunningOutput = true }
                if let start {
                    groups[id]?.processInstances.append("\(pid):\(start)")
                    groups[id]?.canControl = true
                }
            } catch let error as AudioDiscoveryError where error.objectID == processObject && error.status == kAudioHardwareBadObjectError {
                // The process exited after the system list was read.
                continue
            }
        }

        return groups.map { id, group in
            AudioApp(id: id, name: group.name, processIDs: group.processIDs, processInstances: group.processInstances, bundleURL: group.bundleURL, canControl: group.canControl, isRunningOutput: group.isRunningOutput)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Uses Safari's name and icon as a presentation hint only. This does not
    /// establish process ownership or change the process group used by a tap.
    static func safariPresentationURL(processName: String?, bundleID: String?, candidates: [URL]) -> URL? {
        guard processName == "Safari Graphics and Media", bundleID == "com.apple.WebKit.GPU" else { return nil }
        let unique = Set(candidates.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        return unique.count == 1 ? unique.first : nil
    }

    /// Returns the output devices currently used by the given process objects.
    static func processOutputDevices(_ processIDs: [AudioObjectID]) throws -> Set<AudioObjectID> {
        var devices: Set<AudioObjectID> = []
        for process in processIDs {
            devices.formUnion(try objectIDs(
                object: process,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            ))
        }
        return devices
    }


    static func outputDevices() throws -> [OutputDevice] {
        let devices = try objectIDs(object: systemObject, selector: kAudioHardwarePropertyDevices)
        var result: [OutputDevice] = []
        for device in devices {
            let streams = try objectIDs(
                object: device,
                selector: kAudioDevicePropertyStreams,
                scope: kAudioObjectPropertyScopeOutput
            )
            guard !streams.isEmpty else { continue }
            let name = try string(object: device, selector: kAudioObjectPropertyName)
            guard let name, !name.isEmpty else {
                throw AudioDiscoveryError(
                    operation: "Reading device name",
                    objectID: device,
                    selector: kAudioObjectPropertyName,
                    status: kAudioHardwareUnspecifiedError
                )
            }
            result.append(OutputDevice(id: device, name: name))
        }
        return result.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Throws if the system has no default output or the property cannot be read.
    static func defaultOutputDevice() throws -> AudioObjectID {
        let device = try scalar(
            object: systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown)
        )
        guard device != kAudioObjectUnknown else {
            throw AudioDiscoveryError(
                operation: "Finding default output device",
                objectID: systemObject,
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                status: kAudioHardwareBadDeviceError
            )
        }
        return device
    }

    /// Changes the system default output, not the separate system-sound device.
    /// Core Audio rejects unavailable, unsuitable, or unauthorized selections.
    static func setDefaultOutputDevice(_ id: AudioObjectID) throws {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = id
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device
        )
        try check(status, operation: "Setting default output device", object: systemObject, selector: address.mSelector)
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(
        _ status: OSStatus,
        operation: String,
        object: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws {
        guard status == noErr else {
            throw AudioDiscoveryError(operation: operation, objectID: object, selector: selector, status: status)
        }
    }

    private static func scalar<T: FixedWidthInteger>(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        initial: T
    ) throws -> T {
        var address = propertyAddress(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        try check(status, operation: "Reading property", object: object, selector: selector)
        guard Int(size) == MemoryLayout<T>.size else {
            throw AudioDiscoveryError(operation: "Reading property size", objectID: object, selector: selector, status: kAudioHardwareBadPropertySizeError)
        }
        return value
    }

    fileprivate static func objectIDs(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var address = propertyAddress(selector, scope: scope)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
        try check(sizeStatus, operation: "Reading property size", object: object, selector: selector)
        guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0 else {
            throw AudioDiscoveryError(operation: "Reading property size", objectID: object, selector: selector, status: kAudioHardwareBadPropertySizeError)
        }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        let status = values.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(status, operation: "Reading property", object: object, selector: selector)
        guard Int(size) % MemoryLayout<AudioObjectID>.stride == 0,
              Int(size) <= values.count * MemoryLayout<AudioObjectID>.stride else {
            throw AudioDiscoveryError(operation: "Reading property size", objectID: object, selector: selector, status: kAudioHardwareBadPropertySizeError)
        }
        values.removeLast(values.count - Int(size) / MemoryLayout<AudioObjectID>.stride)
        return values
    }

    private static func string(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        try check(status, operation: "Reading string property", object: object, selector: selector)
        guard Int(size) == MemoryLayout<Unmanaged<CFString>?>.size else {
            throw AudioDiscoveryError(operation: "Reading property size", objectID: object, selector: selector, status: kAudioHardwareBadPropertySizeError)
        }
        return value.map { $0.takeRetainedValue() as String }
    }

    /// Metadata lookup can fail for an exited or inaccessible process; attribution
    /// then falls back to the Core Audio bundle ID or the PID, not an invented URL.
    private static func processExecutableURL(_ pid: pid_t) -> URL? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }

    private static func processStart(_ pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    private static func enclosingApplication(_ url: URL?) -> URL? {
        guard var current = url?.standardizedFileURL else { return nil }
        var outermost: URL?
        while current.path != "/" {
            if current.pathExtension.lowercased() == "app" {
                outermost = current
            }
            current.deleteLastPathComponent()
        }
        return outermost
    }

    private static func bundleName(_ bundle: Bundle?) -> String? {
        guard let bundle else { return nil }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.localizedInfoDictionary?["CFBundleName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Tracks the process list and each process's output activity and devices.
/// Listener bookkeeping is serialized; notifications are delivered on the main queue.
final class AudioDiscoveryObserver {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let lock = NSLock()
    private let onChange: () -> Void
    private var listeners: [Listener] = []
    private var stopped = false

    init(onChange: @escaping () -> Void) throws {
        self.onChange = onChange
        do {
            try installSystemListener()
            try refreshProcesses()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    /// Reconciles listeners with the current Core Audio process-object list.
    /// A partial reconciliation is retained and can be retried after an error.
    func refreshProcesses() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }

        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes = Set(try AudioDiscovery.objectIDs(
            object: system,
            selector: kAudioHardwarePropertyProcessObjectList
        ))
        var firstError: AudioDiscoveryError?
        var retained: [Listener] = []
        for var listener in listeners {
            if listener.object == system || processes.contains(listener.object) {
                retained.append(listener)
                continue
            }
            let status = AudioObjectRemovePropertyListenerBlock(
                listener.object, &listener.address, DispatchQueue.main, listener.block
            )
            if status != noErr && status != kAudioHardwareBadObjectError {
                retained.append(listener)
                if firstError == nil {
                    firstError = AudioDiscoveryError(
                        operation: "Removing process listener", objectID: listener.object,
                        selector: listener.address.mSelector, status: status
                    )
                }
            }
        }
        listeners = retained

        for process in processes {
            for (selector, scope) in [
                (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
            ] {
                guard !listeners.contains(where: {
                    $0.object == process && $0.address.mSelector == selector && $0.address.mScope == scope
                }) else { continue }
                do {
                    try addListener(object: process, selector: selector, scope: scope, refresh: false)
                } catch let error as AudioDiscoveryError {
                    // A process may vanish before its listeners are installed.
                    if error.objectID == process && error.status == kAudioHardwareBadObjectError { break }
                    if firstError == nil { firstError = error }
                }
            }
        }
        if let firstError { throw firstError }
    }

    /// Stops notifications and unregisters listeners. Safe to call more than once.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        var retained: [Listener] = []
        for var listener in listeners {
            let status = AudioObjectRemovePropertyListenerBlock(
                listener.object, &listener.address, DispatchQueue.main, listener.block
            )
            if status != noErr && status != kAudioHardwareBadObjectError {
                retained.append(listener)
            }
        }
        listeners = retained
    }

    private func installSystemListener() throws {
        lock.lock()
        defer { lock.unlock() }
        try addListener(
            object: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal,
            refresh: true
        )
    }

    // Called with lock held.
    private func addListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        refresh: Bool
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleChange(refresh: refresh)
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block)
        guard status == noErr else {
            throw AudioDiscoveryError(
                operation: "Adding process listener", objectID: object, selector: selector, status: status
            )
        }
        listeners.append(Listener(object: object, address: address, block: block))
    }

    private func handleChange(refresh: Bool) {
        // Reconciliation errors can be obtained by calling refreshProcesses()
        // from onChange; always notify so the caller can react to the failure.
        if refresh { try? refreshProcesses() }
        lock.lock()
        let shouldNotify = !stopped
        lock.unlock()
        if shouldNotify { onChange() }
    }
}
