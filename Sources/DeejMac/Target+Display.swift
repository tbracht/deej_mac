import AppKit

extension Target {
    var displayName: String {
        switch self {
        case .master: return "Master volume"
        case .mic: return "Microphone"
        case .unmapped: return "Everything else"
        case .app(let id):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            }
            return id
        }
    }

    /// The app's own icon, or an SF Symbol that reflects the current level.
    func icon(level: Float) -> NSImage? {
        let symbol: String
        switch self {
        case .app(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .master:
            symbol = level == 0 ? "speaker.slash.fill"
                : level < 0.34 ? "speaker.wave.1.fill"
                : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .mic:
            symbol = level == 0 ? "mic.slash.fill" : "mic.fill"
        case .unmapped:
            symbol = "square.stack.3d.up.fill"
        }
        return NSImage(systemSymbolName: symbol, accessibilityDescription: displayName)
    }
}
