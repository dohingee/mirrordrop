import Foundation

/// Reads the broadcast extension's status from the App Group (Darwin notification + 1 s polling).
final class BroadcastMonitor: ObservableObject {
    @Published private(set) var status = BroadcastStatus()
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let monitor = Unmanaged<BroadcastMonitor>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { monitor.reload() }
            },
            AppGroup.statusNotification as CFString, nil, .deliverImmediately)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        reload()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
        timer?.invalidate()
    }

    func reload() {
        now = Date()
        if let latest = StatusStore.read(), latest != status { status = latest }
    }

    /// The extension writes at least every 0.5 s while running; older than this means it died.
    var isStale: Bool {
        switch status.state {
        case .starting, .streaming: return now.timeIntervalSince(status.updatedAt) > 5
        default: return false
        }
    }

    var isLive: Bool { (status.state == .starting || status.state == .streaming) && !isStale }

    /// Set once enough segments exist for the TV to start playing.
    var readyURL: URL? {
        guard status.state == .streaming, !isStale, let url = status.url else { return nil }
        return URL(string: url)
    }

    var stateText: String {
        if isStale { return "응답 없음 (공유가 끝났거나 확장이 종료됨)" }
        switch status.state {
        case .idle: return "대기"
        case .starting: return status.url == nil ? "시작 중…" : "영상 조각 만드는 중…"
        case .streaming: return "방송 중"
        case .stopped: return "중지됨"
        case .failed: return "실패"
        }
    }
}
