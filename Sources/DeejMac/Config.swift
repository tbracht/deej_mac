import Foundation

/// What a slider controls. Stored as plain strings so the JSON config stays hand-editable,
/// mirroring deej's config.yaml: "master", "mic", "unmapped", or an app bundle ID.
enum Target: Hashable {
    case master
    case mic
    case unmapped
    case app(String)

    init(_ raw: String) {
        switch raw {
        case "master": self = .master
        case "mic": self = .mic
        case "unmapped", "deej.unmapped": self = .unmapped
        default: self = .app(raw)
        }
    }

    var raw: String {
        switch self {
        case .master: "master"
        case .mic: "mic"
        case .unmapped: "unmapped"
        case .app(let id): id
        }
    }
}

struct Config: Codable {
    /// Pinned serial port, e.g. "/dev/cu.usbserial-21340". nil = auto-detect the deej board.
    var port: String?
    /// The port where auto-detection last found the deej board; it is tried first.
    var knownBoard: String?
    var baudRate = 9600
    var invertSliders = false
    /// Briefly show a HUD below the menu bar when a slider moves.
    var showOverlay = true
    /// Slider index → targets, e.g. [["master"], ["com.spotify.client"], ["com.google.Chrome", "com.hnc.Discord"]]
    var sliders: [[String]] = [["master"]]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(String.self, forKey: .port)
        knownBoard = try c.decodeIfPresent(String.self, forKey: .knownBoard)
        baudRate = try c.decodeIfPresent(Int.self, forKey: .baudRate) ?? baudRate
        invertSliders = try c.decodeIfPresent(Bool.self, forKey: .invertSliders) ?? invertSliders
        showOverlay = try c.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? showOverlay
        sliders = try c.decodeIfPresent([[String]].self, forKey: .sliders) ?? sliders
    }

    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeejMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    func targets(for slider: Int) -> [Target] {
        slider < sliders.count ? sliders[slider].map(Target.init) : []
    }

    mutating func setTargets(_ targets: [Target], for slider: Int) {
        while sliders.count <= slider { sliders.append([]) }
        sliders[slider] = targets.map(\.raw)
    }
}
