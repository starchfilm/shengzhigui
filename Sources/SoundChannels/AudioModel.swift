import AppKit
import Combine
import CoreAudio

struct AppSetting: Codable {
    var volume: Double = 1
    var muted = false
    var outputUID = ""
}

@MainActor final class AudioModel: ObservableObject {
    @Published var devices: [OutputDevice] = []
    @Published var applications: [AudioApplication] = []
    @Published var defaultOutput: UInt32 = 0
    @Published var settings: [String: AppSetting] = [:]
    @Published var enabled: Set<String> = []
    @Published var starting: Set<String> = []
    @Published var error: String?
    @Published var masterVolume: Double = 1
    @Published var masterVolumeAvailable = false
    var adjustingMasterVolume = false
    private var routeStates: [String: RouteSnapshot] = [:]
    private let controller = AudioController()
    private var generations: [String: UUID] = [:]
    private let hardwareQueue = DispatchQueue(label: "com.starchfilm.SoundChannels.hardware", qos: .userInitiated)
    private var refreshing = false
    private var sampling = false
    private var pendingSave: DispatchWorkItem?
    private var timer: Timer?
    private var meterTimer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "appSettings"),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) { settings = saved }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.sampling else { return }
                self.sampling = true
                self.controller.sample { [weak self] states in
                    guard let self else { return }
                    self.sampling = false
                    self.routeStates = states
                }
            }
        }
    }
    func setting(_ id: String) -> AppSetting { settings[id] ?? AppSetting() }
    func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistSettings() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "appSettings") }
    }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        hardwareQueue.async {
            let devices = Hardware.devices
            let output = Hardware.defaultOutput
            let applications = Hardware.applications
            let volume = Hardware.outputVolume(output)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshing = false
                if self.devices != devices { self.devices = devices }
                self.defaultOutput = output
                // Keep rows in place while audio activity changes.
                let order = self.applications.map(\.id)
                self.applications = applications.sorted {
                    let left = order.firstIndex(of: $0.id) ?? Int.max
                    let right = order.firstIndex(of: $1.id) ?? Int.max
                    if left != right { return left < right }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                if !self.adjustingMasterVolume {
                    self.masterVolumeAvailable = volume != nil
                    if let volume { self.masterVolume = Double(volume) }
                }
                self.reconcileRoutes()
            }
        }
    }
    private func reconcileRoutes() {
        for id in Array(enabled) {
            guard let app = applications.first(where: { $0.id == id }) else {
                disable(id); continue
            }
            let s = setting(id)
            guard s.outputUID.isEmpty || devices.contains(where: { $0.uid == s.outputUID }) else {
                disable(id)
                error = "\(app.name)的输出设备已断开，已恢复应用原来的播放路径。"
                continue
            }
            let device = selectedDevice(id)
            if let route = routeStates[id], route.processes != app.processes.sorted() || route.deviceUID != device?.uid || !route.running {
                start(app)
            }
        }
    }
    private func selectedDevice(_ id: String) -> OutputDevice? {
        let uid = setting(id).outputUID
        return devices.first { uid.isEmpty ? $0.id == defaultOutput : $0.uid == uid }
    }
    func setDefaultOutput(_ id: UInt32) {
        guard id != defaultOutput else { return }
        defaultOutput = id
        hardwareQueue.async {
            let result = Result { try Hardware.set(Hardware.system, kAudioHardwarePropertyDefaultOutputDevice, id) }
            DispatchQueue.main.async {
                if case .failure(let error) = result { self.error = error.localizedDescription }
                self.refresh()
            }
        }
    }
    func setMasterVolume(_ volume: Double) {
        masterVolume = volume
        let device = defaultOutput
        hardwareQueue.async {
            do { try Hardware.setOutputVolume(device, Float(volume)) }
            catch { DispatchQueue.main.async { self.error = error.localizedDescription } }
        }
    }
    func setVolume(_ id: String, _ volume: Double) {
        var s = setting(id); s.volume = volume; settings[id] = s
        controller.setGain(id, s.muted ? 0 : Float(volume)); save()
    }
    func setMuted(_ id: String) {
        var s = setting(id); s.muted.toggle(); settings[id] = s
        controller.setGain(id, s.muted ? 0 : Float(s.volume)); save()
    }
    func setOutput(_ app: AudioApplication, _ uid: String) {
        guard setting(app.id).outputUID != uid, !starting.contains(app.id) else { return }
        var s = setting(app.id); s.outputUID = uid; settings[app.id] = s; save()
        if enabled.contains(app.id) { start(app) }
    }
    func toggle(_ app: AudioApplication, _ on: Bool) {
        if on { start(app) } else { disable(app.id) }
    }
    private func start(_ app: AudioApplication) {
        guard !starting.contains(app.id) else { return }
        guard let device = selectedDevice(app.id) else {
            enabled.remove(app.id); error = "没有找到可用的输出设备。"; return
        }
        let s = setting(app.id)
        let generation = UUID()
        generations[app.id] = generation
        starting.insert(app.id)
        controller.configure(app: app, device: device, gain: s.muted ? 0 : Float(s.volume), generation: generation) { [weak self] result in
                guard let self, self.generations[app.id] == generation else {
                    self?.controller.stop(app.id, generation: generation)
                    return
                }
                self.starting.remove(app.id)
                switch result {
                case .success(let state):
                    self.routeStates[app.id] = state
                    self.enabled.insert(app.id)
                    let latest = self.setting(app.id)
                    self.controller.setGain(app.id, latest.muted ? 0 : Float(latest.volume))
                case .failure(let error):
                    self.error = error.localizedDescription
                    if let previous = self.routeStates[app.id] {
                        var restored = self.setting(app.id)
                        restored.outputUID = previous.deviceUID
                        self.settings[app.id] = restored
                        self.save()
                    }
                }
        }
    }
    func disable(_ id: String) {
        generations.removeValue(forKey: id); starting.remove(id)
        controller.stop(id); routeStates.removeValue(forKey: id); enabled.remove(id)
    }
    var canRestoreAll: Bool {
        !enabled.isEmpty || !starting.isEmpty || settings.values.contains {
            $0.volume != 1 || $0.muted || !$0.outputUID.isEmpty
        }
    }
    func restoreAll() {
        settings.removeAll()
        pendingSave?.cancel()
        persistSettings()
        stopAll()
    }
    private func stopAll() {
        generations.removeAll(); starting.removeAll()
        controller.stopAll()
        routeStates.removeAll(); enabled.removeAll()
    }
    func quit() {
        pendingSave?.cancel(); persistSettings()
        controller.stopAll { NSApp.terminate(nil) }
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
