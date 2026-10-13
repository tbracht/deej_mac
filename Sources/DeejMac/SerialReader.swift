import Foundation

/// Reads deej lines ("512|1023|0|...\r\n") from a USB serial port on a background thread.
/// Reconnects automatically when the board is unplugged or not yet present.
final class SerialReader {
    var onValues: (([Int]) -> Void)?
    var onConnectionChange: ((String?) -> Void)?

    private let preferredPort: String?
    private let baudRate: speed_t
    private var thread: Thread?
    private var running = false

    init(port: String?, baudRate: Int) {
        self.preferredPort = port
        self.baudRate = speed_t(baudRate)
    }

    func start() {
        guard !running else { return }
        running = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "deej-serial"
        t.start()
        thread = t
    }

    func stop() { running = false }

    /// Candidate USB serial ports: CH340 clones show up as usbserial/wchusbserial, genuine boards as usbmodem.
    static func detectPorts() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return entries
            .filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") || $0.hasPrefix("cu.usbmodem") }
            .sorted()
            .map { "/dev/" + $0 }
    }

    private func loop() {
        while running {
            guard let path = preferredPort ?? Self.detectPorts().first,
                  let fd = open(path: path) else {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            onConnectionChange?(path)
            readLines(fd: fd)
            close(fd)
            onConnectionChange?(nil)
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func open(path: String) -> Int32? {
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }

        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        cfsetispeed(&tio, baudRate)
        cfsetospeed(&tio, baudRate)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // Block until at least one byte arrives, or 0.5s passes, so we notice unplugging.
        tio.c_cc.16 = 0 // VMIN
        tio.c_cc.17 = 5 // VTIME (tenths of a second)
        guard tcsetattr(fd, TCSANOW, &tio) == 0 else { Darwin.close(fd); return nil }

        // Back to blocking reads now that the port is configured.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        tcflush(fd, TCIFLUSH)
        return fd
    }

    private func readLines(fd: Int32) {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256)
        var idleReads = 0

        while running {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { return } // device gone
            if n == 0 {
                // A board that stops talking for ~5s is treated as disconnected.
                idleReads += 1
                if idleReads > 10 { return }
                continue
            }
            idleReads = 0
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                if let values = Self.parse(line) { onValues?(values) }
            }
            if buffer.count > 1024 { buffer.removeAll() } // garbage without newlines
        }
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
