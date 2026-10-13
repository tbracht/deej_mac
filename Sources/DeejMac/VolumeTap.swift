import AudioToolbox
import CoreAudio
import Foundation

/// Per-app volume via Core Audio process taps (macOS 14.2+).
///
/// The tap mutes the selected processes and hands us their mixed audio. A private aggregate
/// device (the current output device + the tap) lets us play that audio back, multiplied by `gain`.
final class VolumeTap {
    enum Mode { case include, excludeAllBut }

    /// Target gain (0...1), read on the real-time audio thread.
    var gain: Float {
        get { gainBox.target }
        set { gainBox.target = newValue }
    }

    private final class GainBox { var target: Float = 1; var current: Float = 1 }
    private let gainBox = GainBox()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "deej.tap", qos: .userInteractive)

    /// - Parameters:
    ///   - processes: audio process objects to tap (`.include`) or to leave alone (`.excludeAllBut`, i.e. "everything else").
    init(processes: [AudioObjectID], mode: Mode, outputDevice: AudioDeviceID, gain: Float) throws {
        gainBox.target = gain
        gainBox.current = gain

        let description: CATapDescription
        switch mode {
        case .include: description = CATapDescription(stereoMixdownOfProcesses: processes)
        case .excludeAllBut: description = CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
        }
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "deej-mac tap"

        try check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")

        guard let outputUID = AudioSystem.deviceUID(outputDevice) else {
            stop()
            throw TapError("output device has no UID")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "deej-mac",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        do {
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
            let box = gainBox
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, _, output, _ in
                VolumeTap.render(input: input, output: output, gain: box)
            }, "create IO proc")
            try check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Real-time callback: copy the tapped stereo audio to the output, applying a smoothed gain.
    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               gain: GainBox) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        // The tap is the last input stream (the output device's own inputs, if any, come first).
        guard let tapBuffer = inputs.last, let src = tapBuffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        let inChannels = max(1, Int(tapBuffer.mNumberChannels))
        let inFrames = Int(tapBuffer.mDataByteSize) / (4 * inChannels)

        // Ramp linearly towards the target gain over one buffer to avoid clicks.
        let start = gain.current, end = gain.target
        gain.current = end

        // Fill the first two output channels (left/right), whether interleaved or one buffer per channel.
        var channel = 0
        for outBuffer in outputs where channel < 2 {
            guard let dst = outBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = max(1, Int(outBuffer.mNumberChannels))
            let frames = min(inFrames, Int(outBuffer.mDataByteSize) / (4 * outChannels))
            guard frames > 0 else { continue }
            let step = (end - start) / Float(frames)
            for c in 0..<outChannels where channel + c < 2 {
                let srcChannel = min(channel + c, inChannels - 1)
                var g = start
                for f in 0..<frames {
                    dst[f * outChannels + c] = src[f * inChannels + srcChannel] * g
                    g += step
                }
            }
            channel += outChannels
        }
    }
}

struct TapError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw TapError("\(what) failed (OSStatus \(status))") }
}
