import XCTest
import AVFoundation
import CoreAudio
import AudioBridge
@testable import SoundChannels

final class AudioRouteTests: XCTestCase {
    // Opt in on a Mac with system-audio capture permission. Emits a very quiet
    // synthetic signal; does not record any other application's audio.
    func testRestoreReleasesSourceAndCaptureResources() throws {
        guard ProcessInfo.processInfo.environment["SOUNDCHANNELS_AUDIO_INTEGRATION"] == "1" else {
            throw XCTSkip("Requires local audio hardware and capture permission")
        }
        let device = try XCTUnwrap(Hardware.devices.first { $0.id == Hardware.defaultOutput })
        let initialVolume = Hardware.outputVolume(device.id)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 12))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 997 / 48000) * 0.001)
            }
        }
        let file = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        try file.write(from: buffer)
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [fileURL.path]
        try player.run()
        defer { if player.isRunning { player.terminate(); player.waitUntilExit() } }
        Thread.sleep(forTimeInterval: 0.5)
        let processes = Hardware.list(Hardware.system, kAudioHardwarePropertyProcessObjectList).filter {
            (try? Hardware.value($0, kAudioProcessPropertyPID, initial: pid_t(0))) == player.processIdentifier
        }
        XCTAssertFalse(processes.isEmpty)
        let app = AudioApplication(id: "test.restore", name: "Restoration test", icon: nil, processes: processes, playing: true)
        let meter = try NativeOutputMeter(processes: processes, device: device)
        let monitoredTaps = Set(Hardware.list(Hardware.system, kAudioHardwarePropertyTapList))
        XCTAssertGreaterThan(meter.measurePeak(), 0.0001, "Synthetic source must reach native output before control")
        let controller = AudioController()
        for gain: Float in [0.5, 0, 1] {
            let started = expectation(description: "Start app control")
            controller.configure(app: app, device: device, gain: gain, generation: UUID()) { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                started.fulfill()
            }
            wait(for: [started], timeout: 5)
            Thread.sleep(forTimeInterval: 0.4)
            let stopped = expectation(description: "Restore system playback")
            controller.stopAll { result in
                if case .failure(let error) = result { XCTFail("\(error)") }
                stopped.fulfill()
            }
            wait(for: [stopped], timeout: 5)
            Thread.sleep(forTimeInterval: 0.3)
            XCTAssertGreaterThan(meter.measurePeak(), 0.0001, "Native output must remain audible after restore, including from mute")
            XCTAssertEqual(Set(Hardware.list(Hardware.system, kAudioHardwarePropertyTapList)), monitoredTaps)
            XCTAssertEqual(Hardware.defaultOutput, device.id)
            XCTAssertEqual(Hardware.outputVolume(device.id), initialVolume)
            XCTAssertTrue(player.isRunning)
            XCTAssertTrue(processes.contains {
                (try? Hardware.value($0, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) == 1
            })
        }
    }
}

// Measures only the synthetic player's signal at its physical output stream.
// Audio stays in memory; no microphone or audio recording file is used.
private final class NativeOutputMeter {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private var bridge: OpaquePointer?
    init(processes: [AudioObjectID], device output: OutputDevice) throws {
        let description = CATapDescription(processes: processes, deviceUID: output.uid, stream: 0)
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tap), "Create test meter")
        let format = try Hardware.value(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Restoration test meter",
            kAudioAggregateDeviceUIDKey: "SoundChannels.test.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString]]
        ]
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create meter device")
        bridge = try XCTUnwrap(SCBridgeCreate(format.mSampleRate, format.mSampleRate))
        try check(AudioDeviceCreateIOProcID(device, { d, n, i, it, o, ot, c in
            SCBridgeCapture(d, n, i, it, o, ot, c)
        }, UnsafeMutableRawPointer(bridge!), &io), "Create meter callback")
        try check(AudioDeviceStart(device, io), "Start meter")
    }
    func measurePeak() -> Float {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
        defer { samples.deallocate() }
        var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 32768, mData: samples))
        var peak: Float = 0
        // Drain old data first; collect only fresh callbacks in the second half.
        for iteration in 0..<16 {
            SCBridgeRender(bridge!, &buffers, 4096)
            Thread.sleep(forTimeInterval: 0.05)
            if iteration >= 8 { peak = max(peak, SCBridgePeak(bridge!)) }
        }
        return peak
    }
    deinit {
        if let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        if device != 0 { AudioHardwareDestroyAggregateDevice(device) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        if let bridge { SCBridgeDestroy(bridge) }
    }
}
