import AppKit
import CoreAudio
import Foundation

@MainActor
final class DeejController: ObservableObject {
    /// Current slider positions, 0...1 (already inverted if configured).
    @Published private(set) var values: [Float] = []
    @Published private(set) var port: String?
    @Published private(set) var tapErrors: [Int: String] = [:]
    @Published var config: Config {
        didSet {
            config.save()
            if config.invertSliders != oldValue.invertSliders { values = values.map { 1 - $0 } }
            refreshTaps()
            values.indices.forEach(apply)
        }
    }

    var sliderCount: Int { max(values.count, config.sliders.count) }

    private struct ActiveTap { let mode: VolumeTap.Mode; let processes: [AudioObjectID]; let tap: VolumeTap }
    private var taps: [Int: ActiveTap] = [:]
    private var tapDevice: AudioDeviceID?
    private let serial: SerialReader
    private var refreshTimer: Timer?
    private let overlay = Overlay()

    /// Ignore jitter of the potentiometers / ADC (deej's "noise reduction").
    private let noiseThreshold: Float = 0.01

    init() {
        let config = Config.load()
        self.config = config
        config.save() // writes the defaults on first launch so the file can be edited
        serial = SerialReader(port: config.port, baudRate: config.baudRate)

        serial.onValues = { [weak self] raw in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(raw) } }
        }
        serial.onConnectionChange = { [weak self] port in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.port = port } }
        }
        serial.start()

        // Apps start and stop playing audio all the time; re-match processes periodically.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTaps() }
        }
        var addr = AudioSystem.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshTaps() }
        }
    }

    func shutdown() {
        serial.stop()
        taps.values.forEach { $0.tap.stop() }
        taps.removeAll()
    }

    // MARK: Slider input

    private func receive(_ raw: [Int]) {
        var incoming = raw.map { Float($0) / 1023 }
        if config.invertSliders { incoming = incoming.map { 1 - $0 } }
        // Snap the ends so a slider pushed all the way really means 0% / 100%.
        incoming = incoming.map { $0 < 0.015 ? 0 : ($0 > 0.985 ? 1 : $0) }

        if incoming.count != values.count {
            values = incoming
            refreshTaps()
            values.indices.forEach(apply)
            return
        }
        for i in incoming.indices where abs(incoming[i] - values[i]) >= noiseThreshold
            || (incoming[i] != values[i] && (incoming[i] == 0 || incoming[i] == 1)) {
            values[i] = incoming[i]
            apply(i)
            showOverlay(for: i)
        }
    }

    private func showOverlay(for slider: Int) {
        guard config.showOverlay else { return }
        let targets = config.targets(for: slider)
        let title = targets.isEmpty ? "Slider \(slider + 1)" : targets.map(\.displayName).joined(separator: ", ")
        overlay.show(title: title, icon: targets.count == 1 ? targets[0].icon(level: values[slider]) : nil, value: values[slider])
    }

    private func apply(_ slider: Int) {
        guard slider < values.count else { return }
        let volume = values[slider]
        for target in config.targets(for: slider) {
            switch target {
            case .master:
                if let device = AudioSystem.defaultOutputDevice {
                    AudioSystem.setVolume(device, scope: kAudioObjectPropertyScopeOutput, volume)
                }
            case .mic:
                if let device = AudioSystem.defaultInputDevice {
                    AudioSystem.setVolume(device, scope: kAudioObjectPropertyScopeInput, volume)
                }
            case .app, .unmapped:
                taps[slider]?.tap.gain = Self.amplitude(volume)
            }
        }
    }

    /// Slider position → linear amplitude. Squaring makes the travel feel closer to the system volume slider.
    private static func amplitude(_ position: Float) -> Float { position * position }

    // MARK: Per-app taps

    private func refreshTaps() {
        guard let device = AudioSystem.defaultOutputDevice else { return }
        if device != tapDevice {
            // Output switched (e.g. headphones plugged in): every aggregate device must be rebuilt.
            taps.values.forEach { $0.tap.stop() }
            taps.removeAll()
            tapDevice = device
        }

        let ownPID = getpid()
        let processes = AudioSystem.processes().filter { $0.pid != ownPID }

        // Each audio process belongs to at most one slider (the first one that names it).
        var claimed: [Int: [AudioObjectID]] = [:]
        var claimedAll = Set<AudioObjectID>()
        for slider in 0..<sliderCount {
            let apps = config.targets(for: slider).compactMap { if case .app(let id) = $0 { id } else { nil } }
            guard !apps.isEmpty else { continue }
            let ids = processes
                .filter { p in !claimedAll.contains(p.objectID) && apps.contains { Self.matches(p.bundleID, $0) } }
                .map(\.objectID)
            claimed[slider] = ids
            claimedAll.formUnion(ids)
        }

        var desired: [Int: (VolumeTap.Mode, [AudioObjectID])] = [:]
        for slider in 0..<sliderCount {
            if config.targets(for: slider).contains(.unmapped) {
                // Our own process plays the re-routed audio of the other taps. It must never be captured
                // again, so "everything else" waits until the audio system knows our process.
                guard let own = AudioSystem.processObject(for: ownPID) else { continue }
                let exclude = claimedAll.subtracting(claimed[slider] ?? []).union([own])
                desired[slider] = (.excludeAllBut, exclude.sorted())
            } else if let ids = claimed[slider], !ids.isEmpty {
                desired[slider] = (.include, ids.sorted())
            }
        }

        for (slider, active) in taps {
            if let want = desired[slider], want.0 == active.mode, want.1 == active.processes { continue }
            active.tap.stop()
            taps[slider] = nil
        }
        for (slider, want) in desired where taps[slider] == nil {
            let gain = slider < values.count ? Self.amplitude(values[slider]) : 1
            do {
                let tap = try VolumeTap(processes: want.1, mode: want.0, outputDevice: device, gain: gain)
                taps[slider] = ActiveTap(mode: want.0, processes: want.1, tap: tap)
                tapErrors[slider] = nil
            } catch {
                tapErrors[slider] = error.localizedDescription
            }
        }
        for slider in tapErrors.keys where desired[slider] == nil { tapErrors[slider] = nil }
    }

    /// "com.google.Chrome" also matches its helpers ("com.google.Chrome.helper", …).
    /// Safari (and other WebKit apps) play audio from the shared WebKit GPU process.
    static func matches(_ bundleID: String?, _ target: String) -> Bool {
        guard let bundleID else { return false }
        if bundleID == target || bundleID.hasPrefix(target + ".") { return true }
        return target == "com.apple.Safari" && bundleID.hasPrefix("com.apple.WebKit")
    }

    // MARK: Editing

    func toggle(_ target: Target, slider: Int) {
        var targets = config.targets(for: slider)
        if let idx = targets.firstIndex(of: target) { targets.remove(at: idx) } else { targets.append(target) }
        config.setTargets(targets, for: slider)
    }
}
