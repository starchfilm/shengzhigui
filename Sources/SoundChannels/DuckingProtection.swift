import CoreAudio

/// Compatibility layer for macOS's undocumented, per-client `duck` property.
/// Only restores unity attenuation; never changes the system volume or boosts samples.
/// Must run off the realtime callback. Unsupported devices are left untouched.
enum DuckingProtection {
    static let selector: AudioObjectPropertySelector = 0x6475636b

    static func restoreUnity(on device: AudioObjectID) -> OSStatus {
        var property = Hardware.address(selector, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &property) else { return kAudioHardwareUnknownPropertyError }
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        let status = AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size)
        guard status == noErr else { return status }
        guard size == 16, AudioObjectIsPropertySettable(device, &property, &writable) == noErr,
              writable.boolValue else { return kAudioHardwareUnsupportedOperationError }
        // Scalar 1, no scheduled timestamp, no additional ramp.
        let payload: [UInt32] = [Float(1).bitPattern, 0, 0, 0]
        return payload.withUnsafeBytes {
            AudioObjectSetPropertyData(device, &property, 0, nil, UInt32($0.count), $0.baseAddress!)
        }
    }
}
