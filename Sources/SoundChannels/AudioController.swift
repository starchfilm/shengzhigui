import Foundation
import CoreAudio
import os

struct RouteSnapshot {
    let processes: [AudioObjectID]
    let deviceUID: String
    let running: Bool
    let peak: Float
}

// All route lifetimes and AVAudioEngine operations stay on one queue.
// The UI receives value snapshots and never waits for hardware setup or teardown.
final class AudioController {
    private let queue = DispatchQueue(label: "com.starchfilm.SoundChannels.audio", qos: .userInitiated)
    private var routes: [String: AudioRoute] = [:]
    private var generations: [String: UUID] = [:]
    private let logger = Logger(subsystem: "com.starchfilm.SoundChannels", category: "Audio")
    private var protectionTimer: DispatchSourceTimer?
    private var protectionStatuses: [AudioObjectID: OSStatus] = [:]

    private func updateProtection() {
        guard !routes.isEmpty else {
            protectionTimer?.cancel(); protectionTimer = nil
            protectionStatuses.removeAll()
            return
        }
        applyProtection()
        if protectionTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.3, repeating: 0.3, leeway: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.applyProtection() }
            protectionTimer = timer
            timer.resume()
        }
    }

    private func applyProtection() {
        let devices = routes.values.reduce(into: Set<AudioObjectID>()) { $0.formUnion($1.protectionDevices) }
        for device in devices where device != kAudioObjectUnknown {
            let status = DuckingProtection.restoreUnity(on: device)
            if protectionStatuses[device] != status {
                logger.notice("Call volume protection device \(device): status \(status)")
                protectionStatuses[device] = status
            }
        }
    }

    func configure(app: AudioApplication, device: OutputDevice, gain: Float, generation: UUID,
                   completion: @escaping (Result<RouteSnapshot, Error>) -> Void) {
        queue.async {
            self.generations[app.id] = generation
            let began = ProcessInfo.processInfo.systemUptime
            let result = Result { () -> RouteSnapshot in
                let route: AudioRoute
                if let existing = self.routes[app.id], existing.processIDs == app.processes.sorted(), existing.isRunning {
                    try existing.switchOutput(to: device)
                    existing.setGain(gain)
                    route = existing
                    let milliseconds = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)
                    self.logger.notice("Reused capture channel; output switch completed in \(milliseconds) ms")
                } else {
                    self.routes.removeValue(forKey: app.id)?.stop()
                    route = try AudioRoute(app: app, device: device, gain: gain)
                    self.routes[app.id] = route
                }
                self.updateProtection()
                return self.snapshot(route)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func setGain(_ id: String, _ gain: Float) {
        queue.async { self.routes[id]?.setGain(gain) }
    }
    func stop(_ id: String, generation: UUID? = nil) {
        queue.async {
            if let generation, self.generations[id] != generation { return }
            self.generations.removeValue(forKey: id)
            self.routes.removeValue(forKey: id)?.stop()
            self.updateProtection()
        }
    }
    func stopAll(completion: (() -> Void)? = nil) {
        queue.async {
            for route in self.routes.values { route.stop() }
            self.routes.removeAll(); self.generations.removeAll()
            self.updateProtection()
            if let completion { DispatchQueue.main.async { completion() } }
        }
    }
    func sample(completion: @escaping ([String: RouteSnapshot]) -> Void) {
        queue.async {
            let values = self.routes.mapValues { self.snapshot($0) }
            DispatchQueue.main.async { completion(values) }
        }
    }
    private func snapshot(_ route: AudioRoute) -> RouteSnapshot {
        RouteSnapshot(processes: route.processIDs, deviceUID: route.deviceUID, running: route.isRunning, peak: route.peak)
    }
}
