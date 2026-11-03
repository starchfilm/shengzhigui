import AVFoundation
import CoreAudio
import AudioBridge

final class AudioRoute {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var bridge: OpaquePointer?
    private var engine: AVAudioEngine?
    private var source: AVAudioSourceNode?
    let processIDs: [AudioObjectID]
    private(set) var deviceUID: String
    private var deviceID: AudioObjectID
    var isRunning: Bool { engine?.isRunning == true }

    var peak: Float { bridge.map(SCBridgePeak) ?? 0 }
    var received: UInt64 { bridge.map(SCBridgeReceived) ?? 0 }
    func setGain(_ value: Float) { if let bridge { SCBridgeSetGain(bridge, value) } }

    init(app: AudioApplication, device: OutputDevice, gain: Float) throws {
        processIDs = app.processes.sorted(); deviceUID = device.uid; deviceID = device.id
        do {
            let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
            description.name = "声之轨 · \(app.name)"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(description, &tap), "建立应用音频通道")
            let format = try Hardware.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32, format.mSampleRate > 0 else {
                throw AudioFailure(operation: "音频格式不受支持", status: kAudioFormatUnsupportedDataFormatError)
            }
            // A tap-only device avoids opening the headset microphone or changing its Bluetooth mode.
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "声之轨 · \(app.name)",
                kAudioAggregateDeviceUIDKey: "SoundChannels.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "建立音频处理设备")
            let engine = AVAudioEngine()
            self.engine = engine
            guard let unit = engine.outputNode.audioUnit else { throw AudioFailure(operation: "打开输出设备", status: -1) }
            var outputID = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputID, UInt32(MemoryLayout.size(ofValue: outputID))), "选择输出设备")
            let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            guard outputRate > 0, let bridge = SCBridgeCreate(format.mSampleRate, outputRate),
                  let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2) else {
                throw AudioFailure(operation: "准备音频缓冲", status: -1)
            }
            self.bridge = bridge
            SCBridgeSetGain(bridge, gain)
            let node = AVAudioSourceNode(format: renderFormat) { _, _, frames, buffers in
                SCBridgeRender(bridge, buffers, frames)
                return noErr
            }
            source = node
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: renderFormat)
            engine.prepare()
            try engine.start()
            try check(AudioDeviceCreateIOProcID(aggregate, { device, now, input, inputTime, output, outputTime, context in
                SCBridgeCapture(device, now, input, inputTime, output, outputTime, context)
            }, UnsafeMutableRawPointer(bridge), &ioProc), "连接应用音频")
            try check(AudioDeviceStart(aggregate, ioProc), "启动应用音频")
        } catch {
            try? stop()
            throw error
        }
    }
    func switchOutput(to device: OutputDevice) throws {
        guard device.uid != deviceUID else { return }
        guard let engine, let unit = engine.outputNode.audioUnit else {
            throw AudioFailure(operation: "切换输出设备", status: -1)
        }
        let previousID = deviceID
        engine.stop()
        do {
            var nextID = device.id
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &nextID, UInt32(MemoryLayout.size(ofValue: nextID))), "切换输出设备")
            // Keep the source format and tap alive. The mixer converts to the new hardware rate.
            engine.prepare()
            try engine.start()
            deviceID = device.id
            deviceUID = device.uid
        } catch {
            var restoreID = previousID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &restoreID, UInt32(MemoryLayout.size(ofValue: restoreID)))
            engine.prepare()
            try? engine.start()
            throw error
        }
    }
    func stop() throws {
        if let ioProc {
            try check(AudioDeviceStop(aggregate, ioProc), "停止应用音频采集")
            try check(AudioDeviceDestroyIOProcID(aggregate, ioProc), "释放应用音频回调")
            self.ioProc = nil
        }
        if aggregate != 0 {
            try check(AudioHardwareDestroyAggregateDevice(aggregate), "释放应用音频设备")
            aggregate = 0
        }
        if tap != 0 {
            try check(AudioHardwareDestroyProcessTap(tap), "释放应用音频通道")
            tap = 0
        }
        engine?.stop()
        if let source { engine?.detach(source) }
        source = nil; engine = nil
        if let bridge { SCBridgeDestroy(bridge); self.bridge = nil }
    }
    deinit { try? stop() }
}
