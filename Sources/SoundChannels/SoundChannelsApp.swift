import SwiftUI
import CoreAudio

@main struct SoundChannelsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AudioModel()
    init() {
        if CommandLine.arguments.contains("--diagnose") {
            let report: [String: Any] = [
                "defaultOutput": Hardware.defaultOutput,
                "devices": Hardware.devices.map { ["id": $0.id, "uid": $0.uid, "name": $0.name] as [String: Any] },
                "applications": Hardware.applications.map { ["id": $0.id, "name": $0.name, "processes": $0.processes, "playing": $0.playing] as [String: Any] }
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let string = String(data: data, encoding: .utf8) { print(string) }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra("声之轨", systemImage: "speaker.wave.2.fill") {
            MixerView(model: model)
        }.menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MixerView: View {
    @ObservedObject var model: AudioModel
    @AppStorage("appsExpanded") private var appsExpanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.path").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("声之轨").font(.headline)
                    Text("让每个声音，各就各位").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("系统输出", systemImage: "speaker.wave.2").font(.subheadline.weight(.medium))
                Picker("系统输出", selection: Binding(get: { model.defaultOutput }, set: { model.setDefaultOutput($0) })) {
                    ForEach(model.devices) { device in Text(device.name).tag(device.id) }
                }.labelsHidden()
                if model.masterVolumeAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: model.masterVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(.secondary)
                        VolumeSlider(value: Binding(get: { model.masterVolume }, set: { model.setMasterVolume($0) }),
                               onEditingChanged: { model.adjustingMasterVolume = $0 })
                            .frame(height: 20)
                            .accessibilityLabel("系统总音量")
                        Text("\(Int((model.masterVolume * 100).rounded()))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    }
                } else {
                    Text("此设备的音量由设备本身控制").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { appsExpanded.toggle() }
            } label: {
                HStack {
                    Text("应用音量").font(.subheadline.weight(.semibold))
                    Spacer()
                    if !model.enabled.isEmpty {
                        Text("\(model.enabled.count) 个正在控制").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(appsExpanded ? 90 : 0)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(appsExpanded ? "收起应用音量" : "展开应用音量")
            if appsExpanded {
            Text("默认跟随上方系统输出；开启后可单独调整应用。")
                .font(.caption).foregroundStyle(.secondary)
            Label("通话音量保护随应用控制开启", systemImage: "phone.badge.waveform")
                .font(.caption).foregroundStyle(.secondary)
            if model.applications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.title2)
                    Text("先播放一段音乐或视频")
                    Text("使用音频的应用会出现在这里").font(.caption)
                }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.applications) { app in AppRow(app: app, model: model) }
                    }
                }.frame(height: min(430, CGFloat(model.applications.count) * 74 + CGFloat(model.enabled.count) * 64))
            }
            }
            if let error = model.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    HStack {
                        Button("查看录制权限") { model.openPrivacy() }
                        Spacer()
                        Button("关闭提示") { model.error = nil }
                    }.font(.caption)
                }
            }
            Divider()
            HStack {
                Button("恢复所有应用") { model.restoreAll() }.disabled(!model.canRestoreAll)
                Spacer()
                Button("退出") { model.quit() }
            }.font(.caption)
        }.padding(18).frame(width: 390)
    }
}

struct AppRow: View {
    let app: AudioApplication
    @ObservedObject var model: AudioModel
    private var isEnabled: Bool { model.enabled.contains(app.id) }
    private var setting: AppSetting { model.setting(app.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                else { Image(systemName: "app.fill").font(.title2).frame(width: 28) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(model.starting.contains(app.id) ? (isEnabled ? "正在切换输出…" : "正在开启音频控制…") : (isEnabled ? "音频控制已开启" : "跟随系统输出"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Toggle("控制\(app.name)", isOn: Binding(get: { isEnabled || model.starting.contains(app.id) }, set: { model.toggle(app, $0) }))
                    .labelsHidden().toggleStyle(ClearSwitchStyle())
            }
            if isEnabled {
                HStack {
                    Button { model.setMuted(app.id) } label: {
                        Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 20)
                    }.buttonStyle(.plain).accessibilityLabel(setting.muted ? "取消静音" : "静音")
                    VolumeSlider(value: Binding(get: { setting.volume }, set: { model.setVolume(app.id, $0) }))
                        .frame(height: 20)
                        .accessibilityLabel("\(app.name)音量")
                    Text("\(Int(setting.volume * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                }
                Picker("输出到", selection: Binding(get: { setting.outputUID }, set: { model.setOutput(app, $0) })) {
                    Text("跟随系统输出").tag("")
                    ForEach(model.devices) { device in Text(device.name).tag(device.uid) }
                }.font(.caption)
                    .disabled(model.starting.contains(app.id))
            }
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ClearSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Capsule()
                    .fill(configuration.isOn ? Color.blue : Color.secondary.opacity(0.28))
                    .frame(width: 34, height: 20)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 16, height: 16).padding(2)
                    }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
                configuration.label
            }.toggleStyle(.switch)
        }
    }
}
