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
        XCTAssertEqual(samples[2046], Float(2046) / 4096, accuracy: 0.001)
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
}
