import AVFoundation

/// Watches the phone's own output volume while the app is in front, so the main screen can say
/// "휴대폰 소리 꺼짐 ✓" when it is at 0. Read-only: the app never changes the system volume.
/// Never interrupts other apps' sound: the session is only activated with a category that mixes
/// with others (`.ambient`), and the app plays nothing.
final class PhoneVolumeMonitor: ObservableObject {
    /// 0...1, or nil when it could not be read.
    @Published private(set) var volume: Float?
    private var observation: NSKeyValueObservation?
    private var activated = false

    var isSilent: Bool { (volume ?? 1) <= 0.001 }

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // The default category (.soloAmbient) would stop other apps' sound when activated.
        if session.category == .soloAmbient {
            try? session.setCategory(.ambient)
        }
        let mixes = session.category == .ambient || session.categoryOptions.contains(.mixWithOthers)
        if mixes, !activated {
            // outputVolume changes are reported reliably only with an active session.
            activated = (try? session.setActive(true)) != nil
        }
        volume = session.outputVolume
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.volume = value }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
        if activated {
            try? AVAudioSession.sharedInstance().setActive(false)
            activated = false
        }
    }
}
