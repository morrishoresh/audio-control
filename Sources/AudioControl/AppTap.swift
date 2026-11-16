import CoreAudio
import Foundation

/// Gain shared between the main thread (writer) and the IO thread (reader).
final class Gain: @unchecked Sendable {
    /// Target gain, written from the main thread.
    var value: Float32
    /// Gain reached at the end of the last IO cycle; only touched on the IO thread.
    var applied: Float32

    init(_ value: Float32) {
        self.value = value
        applied = value
    }
}

struct AudioError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus
    var description: String { "\(step) failed (\(status))" }
}

/// Captures one app's audio with a muted process tap and plays it on a chosen output device at a chosen gain.
/// The tap uses `mutedWhenTapped`, so the app's audio returns to normal as soon as this stops (or this app quits).
@MainActor
final class AppTap {
    let processes: [AudioObjectID]
    let deviceUID: String
    let gain: Gain

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(bundleID: String, processes: [AudioObjectID], deviceID: AudioDeviceID, deviceUID: String, volume: Int) throws {
        self.processes = processes
        self.deviceUID = deviceUID
        gain = Gain(Float32(volume) / 100)

        do {
            try start(bundleID: bundleID, deviceID: deviceID)
        } catch {
            stop()
            throw error
        }
    }

    func setVolume(_ volume: Int) {
        gain.value = Float32(volume) / 100
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func start(bundleID: String, deviceID: AudioDeviceID) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "AudioControl \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Create process tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioControl \(bundleID)",
            kAudioAggregateDeviceUIDKey: AudioDevices.privateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create aggregate device")

        // The aggregate's input streams are the output device's own input streams (e.g. a headset mic), then the tap.
        let deviceInputStreams = AudioDevices.streamCount(deviceID, .input)
        let gain = gain
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            Self.render(input, output, tapStreamsFrom: deviceInputStreams, gain: gain)
        }, "Create IO proc")
        guard let procID else { throw AudioError(step: "Create IO proc", status: -1) }
        disableInputStreams(before: deviceInputStreams, procID: procID)
        try check(AudioDeviceStart(aggregateID, procID), "Start aggregate device")
    }

    /// Turns off the output device's own input streams for the IO proc, so routing never opens its microphone.
    private func disableInputStreams(before count: Int, procID: AudioDeviceIOProcID) {
        guard count > 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, raw) == noErr else { return }
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let flags = (raw + flagsOffset).assumingMemoryBound(to: UInt32.self)
        for index in 0..<min(count, Int(usage.pointee.mNumberStreams)) {
            flags[index] = 0
        }
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, size, raw)
    }

    // MARK: - IO thread

    /// Copies the tap's channels to the output device's channels, applying gain with a per-cycle ramp.
    /// Runs on the real-time IO thread: no allocation, no locks.
    private nonisolated static func render(
        _ inputList: UnsafePointer<AudioBufferList>,
        _ outputList: UnsafeMutablePointer<AudioBufferList>,
        tapStreamsFrom firstTapStream: Int,
        gain: Gain
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputList))
        let outputs = UnsafeMutableAudioBufferListPointer(outputList)
        var inputChannels = 0
        for index in firstTapStream..<max(firstTapStream, inputs.count) {
            inputChannels += Int(inputs[index].mNumberChannels)
        }
        var outputChannels = 0
        for buffer in outputs {
            outputChannels += Int(buffer.mNumberChannels)
        }

        let start = gain.applied
        let end = gain.value
        var channelBase = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard let data = buffer.mData, channels > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float32.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            for frame in 0..<frames {
                let level = start + (end - start) * Float32(frame) / Float32(frames)
                for channel in 0..<channels {
                    let outputChannel = channelBase + channel
                    let value: Float32
                    if outputChannels == 1, inputChannels > 1 {
                        value = (sample(inputs, firstTapStream, 0, frame) + sample(inputs, firstTapStream, 1, frame)) / 2
                    } else if outputChannel < inputChannels {
                        value = sample(inputs, firstTapStream, outputChannel, frame)
                    } else if inputChannels == 1 {
                        value = sample(inputs, firstTapStream, 0, frame)
                    } else {
                        value = 0
                    }
                    samples[frame * channels + channel] = value * level
                }
            }
        }
        gain.applied = end
    }

    /// Sample of the tap's `channel` (counted across the tap's streams) at `frame`, or 0 if absent.
    @inline(__always)
    private nonisolated static func sample(
        _ inputs: UnsafeMutableAudioBufferListPointer,
        _ firstTapStream: Int,
        _ channel: Int,
        _ frame: Int
    ) -> Float32 {
        var remaining = channel
        var index = firstTapStream
        while index < inputs.count {
            let buffer = inputs[index]
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData else { return 0 }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
                guard frame < frames else { return 0 }
                return data.assumingMemoryBound(to: Float32.self)[frame * channels + remaining]
            }
            remaining -= channels
            index += 1
        }
        return 0
    }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw AudioError(step: step, status: status) }
}
