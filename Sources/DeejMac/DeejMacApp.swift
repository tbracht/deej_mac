import AppKit
import SwiftUI

@main
struct DeejMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("deej", systemImage: "slider.vertical.3") {
            ContentView(controller: delegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = DeejController()

    func applicationWillTerminate(_ notification: Notification) {
        // Destroying the taps unmutes the apps immediately.
        controller.shutdown()
    }
}

struct ContentView: View {
    @ObservedObject var controller: DeejController

    private var statusText: String {
        switch controller.serialStatus {
        case .paused: "Serial paused – port released"
        case .searching: controller.config.port.map { "Waiting for \(($0 as NSString).lastPathComponent)…" } ?? "Searching for deej board…"
        case .connected(let path): "Connected: \((path as NSString).lastPathComponent)"
        }
    }

    private var statusColor: Color {
        switch controller.serialStatus {
        case .paused: .orange
        case .searching: .red
        case .connected: .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if controller.sliderCount == 0 {
                Text("No slider data yet.").foregroundStyle(.secondary)
            }
            ForEach(0..<controller.sliderCount, id: \.self) { slider in
                SliderRow(controller: controller, slider: slider)
            }
            HStack {
                Button { controller.addSlider() } label: { Label("Add slider", systemImage: "plus") }
                if controller.canRemoveSlider {
                    Button { controller.removeLastSlider() } label: { Label("Remove last", systemImage: "minus") }
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)

            Divider()
            HStack {
                Picker("Port", selection: $controller.config.port) {
                    Text("Auto-detect").tag(String?.none)
                    ForEach(controller.availablePorts, id: \.path) { port in
                        Text(port.displayName).tag(Optional(port.path))
                    }
                    if let pinned = controller.config.port, !controller.availablePorts.contains(where: { $0.path == pinned }) {
                        Text("\((pinned as NSString).lastPathComponent) (not connected)").tag(Optional(pinned))
                    }
                }
                Toggle("Pause", isOn: $controller.serialPaused)
                    .help("Release the serial port, e.g. while flashing or using a REPL on another board")
            }
            Toggle("Invert sliders", isOn: $controller.config.invertSliders)
            Toggle("Show overlay when a slider moves", isOn: $controller.config.showOverlay)
            HStack {
                Button("Open config file") { NSWorkspace.shared.open(Config.url) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct SliderRow: View {
    @ObservedObject var controller: DeejController
    let slider: Int

    private var value: Float { slider < controller.values.count ? controller.values[slider] : 0 }
    private var targets: [Target] { controller.config.targets(for: slider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(slider + 1)").font(.headline.monospacedDigit()).frame(width: 16)
                    .overlay(alignment: .topTrailing) {
                        if controller.port != nil && slider >= controller.boardSliderCount {
                            Image(systemName: "hand.point.up.left.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .offset(x: 6, y: -4)
                                .help("Not on the board – set by hand only")
                        }
                    }
                Slider(value: Binding(get: { Double(value) }, set: { controller.setManually(slider, Float($0)) }))
                    .controlSize(.small)
                    .frame(width: 110)
                Text("\(Int((value * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                Menu(targets.isEmpty ? "Unassigned" : targets.map(\.displayName).joined(separator: ", ")) {
                    item(.master)
                    item(.mic)
                    item(.unmapped)
                    Divider()
                    ForEach(appChoices(), id: \.self) { id in item(.app(id)) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = controller.tapErrors[slider] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func item(_ target: Target) -> some View {
        Button {
            controller.toggle(target, slider: slider)
        } label: {
            if targets.contains(target) {
                Label(target.displayName, systemImage: "checkmark")
            } else {
                Text(target.displayName)
            }
        }
    }

    /// Running regular apps plus any configured apps that aren't running right now.
    private func appChoices() -> [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
        let configured = controller.config.sliders.flatMap { $0 }.map(Target.init)
            .compactMap { if case .app(let id) = $0 { id } else { nil } }
        return Set(running + configured)
            .filter { $0 != Bundle.main.bundleIdentifier }
            .sorted { Target.app($0).displayName.localizedCaseInsensitiveCompare(Target.app($1).displayName) == .orderedAscending }
    }
}
