import Foundation
import CoreAudio
import AudioToolbox
import Darwin

/// Each route owns a private process tap and an aggregate whose clock is the
/// selected output device. Nothing in the IO callback touches actor state.
@MainActor
final class AudioEngine {
    private var routes: [String: Route] = [:]
    var onRouteFailure: ((String, String) -> Void)?

    init() {}

    func setGain(appID: String, processIDs: [AudioObjectID], gain: Float, outputDeviceID: AudioObjectID) throws {
        guard gain.isFinite && gain >= 0 else {
            remove(appID: appID)
            throw EngineError.message("Invalid volume")
        }
        if gain == 1 {
            remove(appID: appID)
            return
        }

        let ids = Array(Set(processIDs)).sorted()
        guard !ids.isEmpty, !ids.contains(AudioObjectID(kAudioObjectUnknown)) else {
            remove(appID: appID)
            throw EngineError.message("No audio processes are available")
        }
        guard outputDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            remove(appID: appID)
            throw EngineError.message("No output device is available")
        }
        if let route = routes[appID], route.processIDs == ids,
           route.outputDeviceID == outputDeviceID {
            route.setGain(gain)
            return
        }
        // A process must not be muted by two independent taps.
        guard !routes.contains(where: { key, route in
            key != appID && !Set(route.processIDs).isDisjoint(with: ids)
        }) else {
            remove(appID: appID)
            throw EngineError.message("An audio process is already controlled by another application")
        }

        // Tear down first: two active muted-when-tapped routes for the same
        // process would duplicate output and can leave the old device audible.
        remove(appID: appID)
        let route = Route(processIDs: ids, gain: gain, outputDeviceID: outputDeviceID)
        do {
            try route.prepare()
            let token = route.token
            try route.observeFailures { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.routes[appID]?.token == token else { return }
                    self.remove(appID: appID)
                    self.onRouteFailure?(appID, "The audio device changed or playback stopped unexpectedly.")
                }
            }
            try route.start()
            routes[appID] = route
        } catch {
            route.close()
            throw error
        }
    }

    func remove(appID: String) {
        routes.removeValue(forKey: appID)?.close()
    }

    func stopAll() {
        let oldRoutes = routes
        routes.removeAll()
        for route in oldRoutes.values { route.close() }
    }
}

private enum EngineError: LocalizedError {
    case status(String, OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .status(operation, status): return "\(operation) failed (Core Audio error \(status))"
        case let .message(message): return message
        }
    }
}

private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw EngineError.status(operation, status) }
}

private func address(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Reading audio device identifier")
    guard size == MemoryLayout<Unmanaged<CFString>?>.size, let value else {
        throw EngineError.message("The audio device identifier is unavailable")
    }
    return value.takeRetainedValue() as String
}

private func uintProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "Reading audio device state")
    return value
}

private func streamIDs(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
    var property = address(kAudioDevicePropertyStreams, scope: scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Reading audio streams")
    guard size > 0, Int(size) % MemoryLayout<AudioObjectID>.size == 0 else {
        throw EngineError.message("No usable audio streams are available")
    }
    var streams = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    try streams.withUnsafeMutableBytes {
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, $0.baseAddress!), "Reading audio streams")
    }
    guard Int(size) == streams.count * MemoryLayout<AudioObjectID>.size else {
        throw EngineError.message("The audio streams changed while configuring the route")
    }
    return streams
}

private func streamFormats(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [AudioStreamBasicDescription] {
    return try streamIDs(device, scope: scope).map { stream in
        guard stream != AudioObjectID(kAudioObjectUnknown) else { throw EngineError.message("Audio stream is unavailable") }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = address(kAudioStreamPropertyVirtualFormat)
        try check(AudioObjectGetPropertyData(stream, &formatAddress, 0, nil, &formatSize, &format), "Reading audio stream format")
        try validateFormat(format)
        return format
    }
}

private func validateFormat(_ format: AudioStreamBasicDescription) throws {
    let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    guard format.mChannelsPerFrame > 0, format.mChannelsPerFrame <= 1024 else {
        throw EngineError.message("The audio stream channel count is not supported")
    }
    let bytesPerFrame = nonInterleaved ? 4 : 4 * format.mChannelsPerFrame
    guard format.mFormatID == kAudioFormatLinearPCM,
          format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
          format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
          format.mBitsPerChannel == 32, format.mFramesPerPacket == 1,
          format.mBytesPerFrame == bytesPerFrame,
          format.mBytesPerPacket == bytesPerFrame,
          format.mSampleRate.isFinite, format.mSampleRate > 0 else {
        throw EngineError.message("Only packed, native-endian Float32 PCM audio is supported")
    }
}

private func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
    a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID &&
    a.mFormatFlags == b.mFormatFlags && a.mBytesPerPacket == b.mBytesPerPacket &&
    a.mFramesPerPacket == b.mFramesPerPacket && a.mBytesPerFrame == b.mBytesPerFrame &&
    a.mChannelsPerFrame == b.mChannelsPerFrame && a.mBitsPerChannel == b.mBitsPerChannel
}

// Stream configuration is the documented shape of the IOProc buffer list.
private func bufferChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
    var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "Reading audio buffer layout")
    guard Int(size) >= MemoryLayout<AudioBufferList>.size else {
        throw EngineError.message("The audio buffer layout is unavailable")
    }
    let capacity = Int(size)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage), "Reading audio buffer layout")
    guard Int(size) <= capacity, Int(size) >= MemoryLayout<AudioBufferList>.size else {
        throw EngineError.message("The audio buffer layout changed while configuring the route")
    }
    let list = storage.assumingMemoryBound(to: AudioBufferList.self)
    let count = Int(list.pointee.mNumberBuffers)
    let bufferOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
    guard Int(size) >= bufferOffset, count <= (Int(size) - bufferOffset) / MemoryLayout<AudioBuffer>.stride else {
        throw EngineError.message("The audio buffer layout is invalid")
    }
    return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
}

private func expectedBufferChannels(_ formats: [AudioStreamBasicDescription]) -> [UInt32] {
    formats.flatMap { format in
        format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? [UInt32](repeating: 1, count: Int(format.mChannelsPerFrame))
            : [format.mChannelsPerFrame]
    }
}

/// Only the callback writes currentGain; target points to a separately
/// allocated atomic word shared with the main actor.
private struct IOContext {
    let target: UnsafeMutablePointer<Int32>
    let outputChannelOffset: Int
    let channelCount: Int
    var currentGain: Float
}

/// Finds a channel in an interleaved or non-interleaved AudioBufferList.
/// Returns the sample pointer, sample stride and available frame count.
private func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> (UnsafeMutablePointer<Float>, Int, Int)? {
    var remaining = index
    for buffer in list {
        let channels = Int(buffer.mNumberChannels)
        if remaining < channels {
            guard channels > 0, let data = buffer.mData else { return nil }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            return (data.assumingMemoryBound(to: Float.self).advanced(by: remaining), channels, frames)
        }
        remaining -= channels
    }
    return nil
}

// A C-compatible noncapturing callback; no allocation, locks, logging, property
// queries, dispatch or Swift object access occurs on Core Audio's IO thread.
private let renderAudio: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    let destinations = UnsafeMutableAudioBufferListPointer(output)
    for buffer in destinations {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let context else { return noErr }
    let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let state = context.assumingMemoryBound(to: IOContext.self)
    var frames = Int.max
    for index in 0..<state.pointee.channelCount {
        guard let source = channel(sources, index),
              let destination = channel(destinations, state.pointee.outputChannelOffset + index) else { return noErr }
        frames = min(frames, source.2, destination.2)
    }
    guard frames > 0, frames != Int.max else { return noErr }
    let bits = OSAtomicAdd32Barrier(0, state.pointee.target)
    let target = Float(bitPattern: UInt32(bitPattern: bits))
    let start = state.pointee.currentGain
    let step = (target - start) / Float(frames)
    for index in 0..<state.pointee.channelCount {
        guard let source = channel(sources, index),
              let destination = channel(destinations, state.pointee.outputChannelOffset + index) else { return noErr }
        for frame in 0..<frames {
            let gain = start + step * Float(frame + 1)
            destination.0[frame * destination.1] = source.0[frame * source.1] * gain
        }
    }
    state.pointee.currentGain = target
    return noErr
}

// One aggregate per hardware stream avoids relying on an undocumented ordering
// of multiple taps in an aggregate's input buffer list.
private final class Route {
    let token = UUID()
    let processIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID
    private let initialGain: Float
    private var streams: [StreamRoute] = []

    init(processIDs: [AudioObjectID], gain: Float, outputDeviceID: AudioObjectID) {
        self.processIDs = processIDs
        self.initialGain = gain
        self.outputDeviceID = outputDeviceID
    }

    func setGain(_ gain: Float) {
        for stream in streams { stream.setGain(gain) }
    }

    func prepare() throws {
        let formats = try streamFormats(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        guard try bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeOutput) == expectedBufferChannels(formats) else {
            throw EngineError.message("The output device buffer layout is not supported")
        }
        var offset = 0
        for (index, format) in formats.enumerated() {
            let stream = StreamRoute(processIDs: processIDs, gain: initialGain, outputDeviceID: outputDeviceID,
                                     streamIndex: index, channelOffset: offset, outputFormats: formats)
            streams.append(stream)
            try stream.prepare()
            offset += Int(format.mChannelsPerFrame)
        }
    }

    func observeFailures(_ onFailure: @escaping () -> Void) throws {
        for stream in streams { try stream.observeFailures(onFailure) }
    }

    func start() throws {
        for stream in streams { try stream.validateConfiguration() }
        for stream in streams { try stream.start() }
    }

    func close() {
        for stream in streams { stream.close() }
        streams.removeAll()
    }

    deinit { close() }
}

private final class StreamRoute {
    let processIDs: [AudioObjectID]
    private let initialGain: Float
    let outputDeviceID: AudioObjectID
    private let streamIndex: Int
    private let channelOffset: Int
    private let outputFormats: [AudioStreamBasicDescription]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var context: UnsafeMutablePointer<IOContext>?
    private var started = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(processIDs: [AudioObjectID], gain: Float, outputDeviceID: AudioObjectID,
         streamIndex: Int, channelOffset: Int, outputFormats: [AudioStreamBasicDescription]) {
        self.processIDs = processIDs
        self.initialGain = gain
        self.outputDeviceID = outputDeviceID
        self.streamIndex = streamIndex
        self.channelOffset = channelOffset
        self.outputFormats = outputFormats
    }

    func setGain(_ gain: Float) {
        guard let target = context?.pointee.target else { return }
        let newValue = Int32(bitPattern: gain.bitPattern)
        var oldValue = OSAtomicAdd32Barrier(0, target)
        while !OSAtomicCompareAndSwap32Barrier(oldValue, newValue, target) {
            oldValue = OSAtomicAdd32Barrier(0, target)
        }
    }

    func prepare() throws {
        guard try uintProperty(outputDeviceID, kAudioDevicePropertyDeviceIsAlive) != 0 else {
            throw EngineError.message("The output device is unavailable")
        }
        let outputUID = try stringProperty(outputDeviceID, kAudioDevicePropertyDeviceUID)
        guard !outputUID.isEmpty else { throw EngineError.message("The output device has no identifier") }
        let description = CATapDescription(processes: processIDs, deviceUID: outputUID, stream: UInt(streamIndex))
        description.name = "SoundControl application tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating process tap")
        let tapUID = try stringProperty(tapID, kAudioTapPropertyUID)
        guard !tapUID.isEmpty else { throw EngineError.message("The process tap has no identifier") }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundControl output",
            kAudioAggregateDeviceUIDKey: "SoundControl.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Ask the aggregate not to activate the output device's input
            // channels (for example, a headset microphone).
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceInputChannelsKey: 0]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating audio output route")
        var subTapAddress = address(kAudioAggregateDevicePropertySubTapList)
        var subTapSize: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(aggregateID, &subTapAddress, 0, nil, &subTapSize), "Checking active process tap")
        guard subTapSize == MemoryLayout<AudioObjectID>.size else {
            throw EngineError.message("The process tap is not active on the audio route")
        }
        try validateConfiguration()
        guard try uintProperty(outputDeviceID, kAudioDevicePropertyDeviceIsAlive) != 0 else {
            throw EngineError.message("The output device became unavailable")
        }

        let target = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        target.initialize(to: Int32(bitPattern: initialGain.bitPattern))
        let storage = UnsafeMutablePointer<IOContext>.allocate(capacity: 1)
        storage.initialize(to: IOContext(target: target, outputChannelOffset: channelOffset,
                                         channelCount: Int(outputFormats[streamIndex].mChannelsPerFrame), currentGain: initialGain))
        context = storage
        try check(AudioDeviceCreateIOProcID(aggregateID, renderAudio, storage, &ioProc), "Creating audio render callback")
        guard ioProc != nil else { throw EngineError.message("Could not create audio render callback") }
    }

    func validateConfiguration() throws {
        // A single tap must be the aggregate's only input, not an input
        // stream from the physical device.
        let inputFormats = try streamFormats(aggregateID, scope: kAudioObjectPropertyScopeInput)
        let aggregateOutputs = try streamFormats(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        let deviceOutputs = try streamFormats(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
        var tapFormat = AudioStreamBasicDescription()
        var tapFormatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var tapFormatAddress = address(kAudioTapPropertyFormat)
        try check(AudioObjectGetPropertyData(tapID, &tapFormatAddress, 0, nil, &tapFormatSize, &tapFormat), "Reading process tap format")
        try validateFormat(tapFormat)
        guard inputFormats.count == 1,
              sameFormat(inputFormats[0], tapFormat),
              tapFormat.mChannelsPerFrame == outputFormats[streamIndex].mChannelsPerFrame,
              tapFormat.mSampleRate == outputFormats[streamIndex].mSampleRate,
              aggregateOutputs.count == outputFormats.count,
              deviceOutputs.count == outputFormats.count,
              zip(deviceOutputs, outputFormats).allSatisfy({ sameFormat($0.0, $0.1) }),
              zip(aggregateOutputs, outputFormats).allSatisfy({ sameFormat($0.0, $0.1) }),
              try bufferChannels(outputDeviceID, scope: kAudioObjectPropertyScopeOutput) == expectedBufferChannels(deviceOutputs),
              try bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput) == expectedBufferChannels(inputFormats),
              try bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput) == expectedBufferChannels(aggregateOutputs) else {
            throw EngineError.message("The tap and output device have incompatible audio formats or buffer layouts")
        }
    }

    func observeFailures(_ onFailure: @escaping () -> Void) throws {
        let block: AudioObjectPropertyListenerBlock = { _, _ in onFailure() }
        var properties: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (outputDeviceID, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (outputDeviceID, kAudioDevicePropertyDeviceHasChanged, kAudioObjectPropertyScopeGlobal),
            (outputDeviceID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
            (outputDeviceID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
            (aggregateID, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput),
            (aggregateID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            (aggregateID, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
            (aggregateID, kAudioDevicePropertyIOStoppedAbnormally, kAudioObjectPropertyScopeGlobal),
            (tapID, kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal)
        ]
        let observedStreams = try streamIDs(outputDeviceID, scope: kAudioObjectPropertyScopeOutput)
            + streamIDs(aggregateID, scope: kAudioObjectPropertyScopeInput)
            + streamIDs(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        properties.append(contentsOf: observedStreams.map {
            ($0, kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal)
        })
        for (object, selector, scope) in properties {
            var property = address(selector, scope: scope)
            try check(AudioObjectAddPropertyListenerBlock(object, &property, DispatchQueue.main, block), "Observing audio device")
            listeners.append((object, property, block))
        }
    }

    func start() throws {
        guard let ioProc else { throw EngineError.message("The audio route is not ready") }
        // Stop even if start reports an error after partially starting IO.
        started = true
        try check(AudioDeviceStart(aggregateID, ioProc), "Starting audio output route")
        guard try uintProperty(outputDeviceID, kAudioDevicePropertyDeviceIsAlive) != 0 else {
            throw EngineError.message("The output device became unavailable")
        }
    }

    func close() {
        for (object, var property, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &property, DispatchQueue.main, block)
        }
        listeners.removeAll()
        var callbackStopped = !started
        if let ioProc {
            if started && AudioDeviceStop(aggregateID, ioProc) == noErr { callbackStopped = true }
            if AudioDeviceDestroyIOProcID(aggregateID, ioProc) == noErr { callbackStopped = true }
            self.ioProc = nil
        }
        started = false
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if AudioHardwareDestroyAggregateDevice(aggregateID) == noErr { callbackStopped = true }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let context {
            // If Core Audio refused every stop/destroy operation, keep the
            // callback's storage alive rather than risking a use-after-free.
            if callbackStopped {
                context.pointee.target.deinitialize(count: 1)
                context.pointee.target.deallocate()
                context.deinitialize(count: 1)
                context.deallocate()
            }
            self.context = nil
        }
    }

    deinit { close() }
}
