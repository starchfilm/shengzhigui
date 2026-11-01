import AppKit
import SwiftUI

/// Native slider interaction and accessibility, with a track that keeps its
/// colour when the panel is not the key window.
struct VolumeSlider: NSViewRepresentable {
    @Binding var value: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider()
        let cell = VolumeSliderCell()
        cell.trackingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        slider.cell = cell
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: VolumeSlider
        init(_ parent: VolumeSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
}

private final class VolumeSliderCell: NSSliderCell {
    var trackingChanged: ((Bool) -> Void)?

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let progress = max(0, min(1, (doubleValue - minValue) / max(0.0001, maxValue - minValue)))
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        let tracking = super.startTracking(at: startPoint, in: controlView)
        if tracking { trackingChanged?(true) }
        return tracking
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        trackingChanged?(false)
    }
}
