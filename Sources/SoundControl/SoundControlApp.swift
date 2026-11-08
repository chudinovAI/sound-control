import SwiftUI
import AppKit

@main
enum SoundControlApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private let mixer = MixerModel()
    private let panelLimits = PanelLimits()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Sound Control")
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item

        let panel = MixerPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 270),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        let content = NSHostingView(rootView: MixerView(model: mixer, limits: panelLimits) { [weak self] height in
            self?.resizePanel(height: height)
        })
        content.frame = panel.contentLayoutRect
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: panel.contentLayoutRect)
            glass.style = .regular
            glass.cornerRadius = 22
            glass.contentView = content
            panel.contentView = glass
        } else {
            let material = NSVisualEffectView(frame: panel.contentLayoutRect)
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            material.maskImage = Self.panelMask(size: panel.contentLayoutRect.size)
            material.addSubview(content)
            panel.contentView = material
        }
        self.panel = panel

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let location = event.cgEvent?.location, let primary = NSScreen.screens.first else { return }
            let point = NSPoint(x: location.x, y: primary.frame.maxY - location.y)
            DispatchQueue.main.async {
                guard let self else { return }
                if let button = self.statusItem?.button, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point) {
                    return
                }
                self.panel?.orderOut(nil)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown,
               let button = self.statusItem?.button,
               event.window === button.window,
               button.convert(button.bounds, to: nil).contains(event.locationInWindow),
               self.panel?.isVisible == true {
                self.panel?.orderOut(nil)
                return nil
            }
            if event.window !== self.panel, event.window !== self.statusItem?.button?.window {
                self.panel?.orderOut(nil)
            }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            DispatchQueue.main.async { self?.panel?.orderOut(nil) }
        }
    }

    private func resizePanel(height: CGFloat) {
        guard let panel, height.isFinite, height > 0 else { return }
        let height = min(ceil(height), panelLimits.maxHeight)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: 320, height: height), display: true)
        if let material = panel.contentView as? NSVisualEffectView {
            material.maskImage = Self.panelMask(size: panel.contentLayoutRect.size)
        }
    }

    private static func panelMask(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill()
            return true
        }
    }

    @objc private func togglePanel() {
        guard let panel, let button = statusItem?.button, let window = button.window else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        panelLimits.maxHeight = max(1, anchor.minY - visible.minY - 6)
        let x = min(max(anchor.midX - panel.frame.width / 2, visible.minX), visible.maxX - panel.frame.width)
        let height = min(panel.frame.height, panelLimits.maxHeight)
        panel.setFrame(NSRect(x: x, y: anchor.minY - height - 6, width: panel.frame.width, height: height), display: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stop()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

private final class MixerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PanelLimits: ObservableObject {
    @Published var maxHeight: CGFloat = 520
}

private struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var limits: PanelLimits
    let onHeightChange: (CGFloat) -> Void

    private var errorHeight: CGFloat { model.errorMessage == nil ? 0 : 86 }
    private let fixedHeight: CGFloat = 150

    private var naturalListHeight: CGFloat {
        model.apps.isEmpty ? 70 : CGFloat(min(model.apps.count, 4)) * 70
    }

    private var panelHeight: CGFloat {
        min(fixedHeight + naturalListHeight + errorHeight, limits.maxHeight)
    }

    private var listHeight: CGFloat {
        max(0, panelHeight - fixedHeight - errorHeight)
    }

    private var compact: Bool {
        model.errorMessage != nil || limits.maxHeight < fixedHeight + 70
    }

    var body: some View {
        Group {
            if compact {
                ScrollView { panelContent }
            } else {
                panelContent
            }
        }
            .frame(width: 320, height: panelHeight, alignment: .top)
            .preferredColorScheme(.dark)
            .onAppear { onHeightChange(panelHeight) }
            .onChange(of: panelHeight) { _, height in onHeightChange(height) }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            output
                .frame(height: 54)
                .padding(.top, 12)
            if let message = model.errorMessage {
                errorContent(message)
            }
            HStack {
                Text("Apps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("\(model.apps.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 18)
            .frame(height: 32)

            if model.apps.isEmpty {
                Text("No apps playing audio")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 70 : listHeight)
            } else if compact {
                appRows
            } else {
                ScrollView { appRows }
                    .frame(height: listHeight)
            }

            footer
                .frame(height: 40)
                .padding(.bottom, 12)
        }
        .accessibilityElement(children: .contain)
    }

    private var appRows: some View {
        LazyVStack(spacing: 6) {
            ForEach(model.apps) { app in
                AppRow(app: app, model: model)
            }
        }
        .padding(.horizontal, 12)
    }

    private func errorContent(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .padding(12)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }


    private var output: some View {
        Menu {
            ForEach(model.devices) { device in
                Button {
                    model.selectOutput(device.id)
                } label: {
                    if device.id == model.outputDevice {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 17))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Output").font(.system(size: 12, weight: .semibold))
                    Text(model.devices.first(where: { $0.id == model.outputDevice })?.name ?? "No output")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .controlGlass(cornerRadius: 18)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Output device")
        .accessibilityValue(model.devices.first(where: { $0.id == model.outputDevice })?.name ?? "No output")
        .padding(.horizontal, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Quit") {
                model.stop()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppRow: View {
    let app: AudioApp
    @ObservedObject var model: MixerModel

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(app.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(!app.canControl ? "Unavailable" : (model.pending.contains(app.id) ? "Not applied" : (model.isMuted(app) ? "Muted" : "\(Int((model.level(for: app) * 100).rounded()))%")))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 9) {
                    Button { model.toggleMute(app) } label: {
                        Image(systemName: model.isMuted(app) || model.level(for: app) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 17)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(model.isMuted(app) ? 0.55 : 1))
                    .help(model.isMuted(app) ? "Unmute" : "Mute")
                    VolumeSlider(value: Binding(
                        get: { Double(model.level(for: app)) },
                        set: { model.setLevel(Float($0), for: app) }
                    ), label: "\(app.name) volume")
                }
                .disabled(!app.canControl)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .foregroundStyle(.white)
        .controlGlass(cornerRadius: 18)
    }

    private var icon: some View {
        Group {
            if let url = app.bundleURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
                    .padding(7)
            }
        }
        .frame(width: 38, height: 38)
    }
}

private struct VolumeSlider: View {
    @Binding var value: Double
    let label: String

    var body: some View {
        Slider(value: $value, in: 0...1)
            .controlSize(.small)
            .tint(.white)
            .accessibilityLabel(label)
    }
}

private extension View {
    @ViewBuilder
    func controlGlass(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
