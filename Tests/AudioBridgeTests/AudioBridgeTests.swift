import XCTest
import CoreAudio
import AudioBridge

final class AudioBridgeTests: XCTestCase {
    private func feed(_ bridge: OpaquePointer, frames: Int, value: (Int) -> (Float, Float)) {
        var samples = (0..<frames).flatMap { i -> [Float] in let pair = value(i); return [pair.0, pair.1] }
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            var time = AudioTimeStamp()
            XCTAssertEqual(SCBridgeCapture(0, &time, &list, &time, nil, &time, UnsafeMutableRawPointer(bridge)), noErr)
        }
    }
    private func render(_ bridge: OpaquePointer, frames: Int) -> [Float] {
        var samples = [Float](repeating: 99, count: frames * 2)
        samples.withUnsafeMutableBytes { bytes in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            SCBridgeRender(bridge, &list, UInt32(frames))
        }
        return samples
    }
    func testUnderrunProducesSilence() {
        let bridge = SCBridgeCreate(48000, 48000)!
        defer { SCBridgeDestroy(bridge) }
        XCTAssertTrue(render(bridge, frames: 512).allSatisfy { $0 == 0 })
    }
    func testStereoGainAndMute() {
        let bridge = SCBridgeCreate(48000, 48000)!
        defer { SCBridgeDestroy(bridge) }
        feed(bridge, frames: 4096) { _ in (0.8, -0.4) }
        XCTAssertEqual(SCBridgeReceived(bridge), 4096)
        SCBridgeSetGain(bridge, 0.5)
        let samples = render(bridge, frames: 1024)
        XCTAssertEqual(samples[2046], 0.4, accuracy: 0.001)
        XCTAssertEqual(samples[2047], -0.2, accuracy: 0.001)
        SCBridgeSetGain(bridge, 0)
        let muted = render(bridge, frames: 1024)
        XCTAssertLessThan(abs(muted[2046]), 0.001)
    }
    func testSampleRateConversion() {
        let bridge = SCBridgeCreate(48000, 24000)!
        defer { SCBridgeDestroy(bridge) }
        feed(bridge, frames: 4096) { i in (Float(i) / 4096, 0) }
        let samples = render(bridge, frames: 1024)
        XCTAssertEqual(samples[2046], Float(2046 - 31) / 4096, accuracy: 0.001)
        XCTAssertEqual(samples[2047], 0)
    }
    func testBufferCapacityAndRecovery() {
        let bridge = SCBridgeCreate(48000, 48000)!
        defer { SCBridgeDestroy(bridge) }
        feed(bridge, frames: 40000) { _ in (0.2, 0.2) }
        XCTAssertEqual(SCBridgeReceived(bridge), 32768)
        XCTAssertTrue(render(bridge, frames: 4096).allSatisfy { $0.isFinite && abs($0) <= 0.21 })
        feed(bridge, frames: 512) { _ in (0.1, 0.1) }
        XCTAssertEqual(SCBridgeReceived(bridge), 33280)
    }

    private func toneLevel(inputRate: Double, outputRate: Double, frequency: Double) -> (decibels: Double, rightEnergy: Double) {
        let bridge = SCBridgeCreate(inputRate, outputRate)!
        defer { SCBridgeDestroy(bridge) }
        let inputBlock = Int(inputRate / 100), outputBlock = Int(outputRate / 100)
        var energy = 0.0, rightEnergy = 0.0, count = 0
        for block in 0..<300 {
            feed(bridge, frames: inputBlock) { i in
                (Float(0.6 * sin(2 * .pi * frequency * Double(block * inputBlock + i) / inputRate)), 0)
            }
            let output = render(bridge, frames: outputBlock)
            if block >= 100 {
                for i in 0..<outputBlock {
                    energy += Double(output[i * 2] * output[i * 2])
                    rightEnergy += Double(output[i * 2 + 1] * output[i * 2 + 1])
                    count += 1
                }
            }
        }
        return (20 * log10(sqrt(energy / Double(count)) / (0.6 / sqrt(2))), rightEnergy)
    }

    func testCommonCallbackSizesPreserveHighFrequencies() {
        // 480- and 441-frame callbacks previously caused unnecessary drift
        // correction and ~3 dB attenuation at 16 kHz, even at equal rates.
        for rate in [44100.0, 48000.0] {
            let level = toneLevel(inputRate: rate, outputRate: rate, frequency: 16000)
            XCTAssertEqual(level.decibels, 0, accuracy: 0.03)
            XCTAssertEqual(level.rightEnergy, 0)
        }
    }

    func testResamplingPreservesHighFrequencyAndStereoIsolation() {
        for frequency in [997.0, 16000.0] {
            let level = toneLevel(inputRate: 44100, outputRate: 48000, frequency: frequency)
            XCTAssertEqual(level.decibels, 0, accuracy: 0.05)
            XCTAssertEqual(level.rightEnergy, 0)
        }
    }

    func testDownsamplingRejectsAboveNyquistTone() {
        let level = toneLevel(inputRate: 48000, outputRate: 24000, frequency: 16000)
        XCTAssertLessThan(level.decibels, -50)
    }

    func testSteadyStateSampleErrorAndFilterDelay() {
        for blockSize in [480, 512] {
            let bridge = SCBridgeCreate(48000, 48000)!
            defer { SCBridgeDestroy(bridge) }
            var seed: UInt32 = 1234567
            let reference: [Float] = (0..<(blockSize * 120 * 2)).map { _ in
                seed = seed &* 1664525 &+ 1013904223
                return (Float(seed >> 8) / 16777216 - 0.5) * 0.6
            }
            var signal = 0.0, error = 0.0
            for block in 0..<120 {
                let base = block * blockSize
                feed(bridge, frames: blockSize) { i in
                    (reference[(base + i) * 2], reference[(base + i) * 2 + 1])
                }
                let output = render(bridge, frames: blockSize)
                guard block > 10 else { continue }
                for i in 0..<blockSize {
                    for channel in 0..<2 {
                        let expected = Double(reference[(base + i - 32) * 2 + channel])
                        let delta = Double(output[i * 2 + channel]) - expected
                        signal += expected * expected
                        error += delta * delta
                    }
                }
            }
            XCTAssertGreaterThan(10 * log10(signal / max(error, 1e-30)), 105)
        }
    }
}
