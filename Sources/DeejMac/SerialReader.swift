import Foundation
import IOKit
import IOKit.serial

struct SerialPortInfo: Hashable {
    let path: String
    /// Changes whenever the device is re-plugged, so a rejected port gets another chance after replugging.
    let registryID: UInt64
    let productName: String?

    var displayName: String {
        let name = (path as NSString).lastPathComponent
        return productName.map { "\(name) – \($0)" } ?? name
    }
}

/// Reads deej lines ("512|1023|0|...\r\n") from a USB serial port on a background thread.
///
/// Other boards (ESP, MicroPython, …) share the same kind of ports, so in auto mode a port must send
/// valid deej lines within a few seconds of opening. Otherwise it is released and left alone until
/// it is re-plugged. Once the board is confirmed, the port is locked so other tools get "busy"
/// instead of silently sharing the data.
final class SerialReader {
    enum Status: Equatable {
        case paused
        case searching
        case connected(String)
    }

    var onValues: (([Int]) -> Void)?
    var onStatus: ((Status) -> Void)?
    var onPortsChanged: (([SerialPortInfo]) -> Void)?
    /// A port was confirmed to be a deej board (auto mode); it is tried first from now on.
    var onBoardFound: ((String) -> Void)?

    private struct Settings: Equatable {
        var pinnedPort: String?
        var paused = false
        var knownBoard: String?
    }

    private let baudRate: speed_t
    private let lock = NSLock()
    private var settings = Settings()
    /// Bumped when the pinned port or pause changes, ending the current session.
    private var generation = 0
    private var running = false
    private var lastStatus: Status?

    /// How long a port may take to send deej data after opening (the Nano's bootloader runs first).
    private let validationTimeout: TimeInterval = 5
    /// A board that stops talking for this long is treated as disconnected.
    private let silenceTimeout: TimeInterval = 5

    init(baudRate: Int) {
        self.baudRate = speed_t(baudRate)
    }

    func configure(pinnedPort: String?, paused: Bool, knownBoard: String?) {
        lock.lock()
        defer { lock.unlock() }
        if settings.pinnedPort != pinnedPort || settings.paused != paused { generation += 1 }
        settings = Settings(pinnedPort: pinnedPort, paused: paused, knownBoard: knownBoard)
    }

    func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "deej-serial"
        t.start()
    }

    func stop() { running = false }

    private func snapshot() -> (Settings, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (settings, generation)
    }

    private func report(_ status: Status) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }

    // MARK: Connection loop

    private func loop() {
        var rejected = Set<UInt64>()
        var lastPorts: [SerialPortInfo]?

        while running {
            let (settings, generation) = snapshot()
            let ports = Self.availablePorts()
            if ports != lastPorts {
                lastPorts = ports
                onPortsChanged?(ports)
            }
            rejected.formIntersection(ports.map(\.registryID)) // forget ports that were unplugged

            if settings.paused {
                report(.paused)
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            report(.searching)

            let candidates: [SerialPortInfo]
            if let pinned = settings.pinnedPort {
                candidates = ports.filter { $0.path == pinned }
            } else {
                // The board found last time goes first, so other boards aren't touched while it's present.
                let ordered = ports.filter { $0.path == settings.knownBoard } + ports.filter { $0.path != settings.knownBoard }
                candidates = ordered.filter { !rejected.contains($0.registryID) }
            }
            // A port another tool holds exclusively fails to open; move on to the next one.
            // (A plain loop on purpose: a lazy `compactMap(...).first` runs `open` twice and leaks a handle.)
            var opened: (port: SerialPortInfo, fd: Int32)?
            for candidate in candidates {
                if let fd = open(path: candidate.path) {
                    opened = (candidate, fd)
                    break
                }
            }
            guard let (port, fd) = opened else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }

            let validate = settings.pinnedPort == nil
            if !session(fd: fd, port: port, validate: validate, generation: generation) {
                rejected.insert(port.registryID)
            }
            _ = ioctl(fd, TIOCNXCL)
            close(fd)
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Reads one connection until it ends. Returns false if the port didn't turn out to be a deej board.
    private func session(fd: Int32, port: SerialPortInfo, validate: Bool, generation: Int) -> Bool {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        let opened = Date()
        var lastData = Date()
        var confirmed = !validate
        var previousCount: Int?

        if confirmed { report(.connected(port.path)) }

        while running {
            let (_, currentGeneration) = snapshot()
            if currentGeneration != generation { return true } // paused or port changed

            let n = read(fd, &chunk, chunk.count)
            if n < 0 { return true } // device gone
            if n == 0 {
                if !confirmed && Date().timeIntervalSince(opened) > validationTimeout { return false }
                if Date().timeIntervalSince(lastData) > silenceTimeout { return true }
                continue
            }
            lastData = Date()
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                guard let values = Self.parse(line) else {
                    previousCount = nil
                    continue
                }
                if !confirmed {
                    // Two consecutive valid lines with the same slider count: that's deej, not random output.
                    if previousCount == values.count {
                        confirmed = true
                        _ = ioctl(fd, TIOCEXCL)
                        onBoardFound?(port.path)
                        report(.connected(port.path))
                    }
                    previousCount = values.count
                }
                if confirmed { onValues?(values) }
            }
            if buffer.count > 1024 { buffer.removeAll() } // garbage without newlines
            if !confirmed && Date().timeIntervalSince(opened) > validationTimeout { return false }
        }
        return true
    }

    private func open(path: String) -> Int32? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil } // e.g. busy: another tool holds it exclusively

        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        cfsetispeed(&tio, baudRate)
        cfsetospeed(&tio, baudRate)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // Block until at least one byte arrives, or 0.5s passes, so we notice silence and setting changes.
        tio.c_cc.16 = 0 // VMIN
        tio.c_cc.17 = 5 // VTIME (tenths of a second)
        guard tcsetattr(fd, TCSANOW, &tio) == 0 else { Darwin.close(fd); return nil }

        // Back to blocking reads now that the port is configured.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        tcflush(fd, TCIFLUSH)
        return fd
    }

    // MARK: Port discovery

    /// USB serial ports (Bluetooth and debug-console ports are skipped).
    static func availablePorts() -> [SerialPortInfo] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports = [SerialPortInfo]()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { continue }

            func usbProperty(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard usbProperty("idVendor") != nil else { continue }

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            ports.append(SerialPortInfo(path: path, registryID: registryID, productName: usbProperty("USB Product Name") as? String))
        }
        return ports.sorted { $0.path < $1.path }
    }

    /// Parses "169|704|274|556|0". Lines with noise (e.g. the reset burst after opening the port) are rejected.
    static func parse(_ line: String) -> [Int]? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var values = [Int]()
        for p in parts {
            guard let v = Int(p), (0...1023).contains(v) else { return nil }
            values.append(v)
        }
        return values
    }
}
