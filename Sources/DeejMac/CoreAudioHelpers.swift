import AppKit
import AudioToolbox
import CoreAudio

enum AudioSystem {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func getArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: T) -> [T] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: element, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr,
              let str = value?.takeRetainedValue() else { return nil }
        return str as String
    }

    // MARK: Devices

    static var defaultOutputDevice: AudioDeviceID? {
        Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
    }

    static var defaultInputDevice: AudioDeviceID? {
        Self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
    }

    static func deviceUID(_ device: AudioDeviceID) -> String? {
        getString(device, kAudioDevicePropertyDeviceUID)
    }

    static func volume(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Float? {
        get(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, initial: Float32(0))
    }

    /// Sets the same volume macOS's own volume slider controls (works for devices with or without a hardware volume).
    @discardableResult
    static func setVolume(_ device: AudioDeviceID, scope: AudioObjectPropertyScope, _ volume: Float) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var v = Float32(max(0, min(1, volume)))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    // MARK: Processes

    struct AudioProcess {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
    }

    /// Every process currently registered with the audio system.
    static func processes() -> [AudioProcess] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, element: AudioObjectID(0))
            .map { id in
                let pid = get(id, kAudioProcessPropertyPID, initial: pid_t(-1)) ?? -1
                var bundle = getString(id, kAudioProcessPropertyBundleID)
                if bundle?.isEmpty ?? true { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }
                return AudioProcess(objectID: id, pid: pid, bundleID: bundle)
            }
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidIn = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pidIn, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
