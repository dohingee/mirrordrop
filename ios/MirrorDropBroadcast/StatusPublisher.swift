import Foundation

/// Collects the extension's status and publishes it to the App Group at most a few times per second.
final class StatusPublisher {
    private let lock = NSLock()
    private var status = BroadcastStatus()
    private var dirty = false
    private var nextRequestID = 0
    private static let maxLines = 60
    private static let maxRequests = 40

    func update(_ change: (inout BroadcastStatus) -> Void) {
        lock.lock()
        change(&status)
        dirty = true
        lock.unlock()
    }

    func log(_ message: String) {
        let line = Self.stamp() + " " + message
        NSLog("[MirrorDrop] %@", message)
        update { Self.push(line, into: &$0.log) }
    }

    func error(_ message: String) {
        let line = Self.stamp() + " " + message
        NSLog("[MirrorDrop] ERROR %@", message)
        update {
            Self.push(line, into: &$0.errors)
            Self.push("ERROR " + line, into: &$0.log)
        }
    }

    func recordRequest(method: String, path: String, client: String, status code: Int, bytes: Int) {
        update { status in
            status.requestCount += 1
            status.clients[client, default: 0] += 1
            status.recentRequests.append(RequestLogEntry(id: self.nextRequestID, time: Date(), client: client,
                                                         method: method, path: path, status: code, bytes: bytes))
            self.nextRequestID += 1
            if status.recentRequests.count > Self.maxRequests {
                status.recentRequests.removeFirst(status.recentRequests.count - Self.maxRequests)
            }
        }
    }

    func flush(force: Bool = false) {
        lock.lock()
        guard dirty || force else { lock.unlock(); return }
        status.updatedAt = Date()
        let snapshot = status
        dirty = false
        lock.unlock()
        StatusStore.write(snapshot)
    }

    private static func push(_ line: String, into lines: inout [String]) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func stamp() -> String { formatter.string(from: Date()) }
}
