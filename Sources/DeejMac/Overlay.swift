import AppKit
import SwiftUI

/// A small HUD below the menu bar that shows a slider's target and level while it is being moved.
@MainActor
final class Overlay {
    private final class Model: ObservableObject {
        @Published var title = ""
        @Published var icon: NSImage?
        @Published var value: Float = 0
    }

    private let model = Model()
    private var panel: NSPanel?
    private var hideTask: DispatchWorkItem?
    /// Bumped on every change so a fade-out that is already running doesn't hide a fresh update.
    private var generation = 0
    private let visibleDuration: TimeInterval = 1.2
    private let size = NSSize(width: 300, height: 56)

    func show(title: String, icon: NSImage?, value: Float) {
        model.title = title
        model.icon = icon
        model.value = value
        generation += 1

        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.hide() }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: task)
    }

    private func hide() {
        guard let panel else { return }
        let generation = self.generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if self?.generation == generation { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: OverlayView(model: model).frame(width: size.width, height: size.height))
        return panel
    }

    /// Centered just below the menu bar of the screen the mouse is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 10))
    }

    private struct OverlayView: View {
        @ObservedObject var model: Model

        var body: some View {
            HStack(spacing: 12) {
                Group {
                    if let icon = model.icon {
                        Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "slider.vertical.3").resizable().aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    ProgressView(value: Double(model.value)).progressViewStyle(.linear)
                }

                Text("\(Int((model.value * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
