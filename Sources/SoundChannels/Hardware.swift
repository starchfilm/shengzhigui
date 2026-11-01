import AppKit
import CoreAudio
import AudioToolbox

struct AudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? { "\(operation)失败（\(status)）。请检查音频录制权限和设备连接。" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(operation: operation, status: status) }
}

enum Hardware {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        var result = initial, size = UInt32(MemoryLayout<T>.size), prop = address(selector, scope)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, &result), "读取音频属性")
        return result
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: result)), prop = address(selector)
        guard AudioObjectGetPropertyData(object, &prop, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
    static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var prop = address(selector, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &prop, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &prop, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? ids : []
    }
    static func set<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: T) throws {
        var v = value, prop = address(selector)
        try check(AudioObjectSetPropertyData(object, &prop, 0, nil, UInt32(MemoryLayout<T>.size), &v), "设置音频属性")
    }
    static var defaultOutput: AudioObjectID { (try? value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))) ?? 0 }
    private static func volumeAddresses(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var property = address(selector, kAudioDevicePropertyScopeOutput)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &property),
               AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue { return [property] }
        }
        return (1...2).compactMap { channel in
            var property = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
            property.mElement = UInt32(channel)
            var settable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &property) && AudioObjectIsPropertySettable(device, &property, &settable) == noErr && settable.boolValue ? property : nil
        }
    }
    private static func readVolume(_ device: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float? {
        var property = address, volume: Float = 0, size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &volume) == noErr else { return nil }
        return volume
    }
    static func outputVolume(_ device: AudioObjectID) -> Float? {
        volumeAddresses(device).compactMap { readVolume(device, $0) }.max()
    }
    static func setOutputVolume(_ device: AudioObjectID, _ value: Float) throws {
        let properties = volumeAddresses(device)
        guard !properties.isEmpty else { throw AudioFailure(operation: "此设备不支持系统音量调节", status: kAudioHardwareUnsupportedOperationError) }
        let previous = properties.map { readVolume(device, $0) ?? 0 }
        let maximum = previous.max() ?? 0
        for (index, address) in properties.enumerated() {
            var property = address
            var volume = max(0, min(1, value))
            if properties.count > 1, maximum > 0 { volume *= previous[index] / maximum }
            try check(AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<Float>.size), &volume), "调整系统音量")
        }
    }
    static var devices: [OutputDevice] {
        list(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard !list(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput).isEmpty,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix("SoundChannels.") else { return nil }
            let name = string(id, kAudioObjectPropertyName) ?? "音频设备"
            guard !uid.hasPrefix("CADefaultDeviceAggregate-"), !name.hasPrefix("CADefaultDeviceAggregate-") else { return nil }
            return OutputDevice(id: id, uid: uid, name: name)
        }
    }
    static var applications: [AudioApplication] {
        let running = NSWorkspace.shared.runningApplications
        var grouped: [String: AudioApplication] = [:]
        for object in list(system, kAudioHardwarePropertyProcessObjectList) {
            guard let pid = try? value(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid != getpid() else { continue }
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? ""
            let processApp = NSRunningApplication(processIdentifier: pid)
            let parent = running.filter { app in
                guard let id = app.bundleIdentifier, !id.isEmpty else { return false }
                return bundleID == id || bundleID.hasPrefix(id + ".")
            }.min { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            let app = parent ?? processApp
            let key = app?.bundleIdentifier ?? (bundleID.isEmpty ? "pid.\(pid)" : bundleID)
            if key == Bundle.main.bundleIdentifier { continue }
            let active = ((try? value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0) != 0
            guard app?.activationPolicy == .regular || active else { continue }
            if var existing = grouped[key] {
                existing.processes.append(object); existing.playing = existing.playing || active; grouped[key] = existing
            } else {
                grouped[key] = AudioApplication(id: key, name: app?.localizedName ?? (bundleID.isEmpty ? "进程 \(pid)" : bundleID), icon: app?.icon, processes: [object], playing: active)
            }
        }
        return grouped.values.sorted {
            if $0.playing != $1.playing { return $0.playing }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}
struct AudioApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
    var processes: [AudioObjectID]
    var playing: Bool
}
