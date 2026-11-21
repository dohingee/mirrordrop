import Foundation

/// Stream settings to try on a real TV for lower glass-to-glass delay, chosen in the app and
/// read by the extension when a broadcast starts (stored in the App Group as `rawValue`).
/// Every preset keeps the RFC 8216 6.2.2 rule: playlist window >= 3 x EXT-X-TARGETDURATION.
/// Stored seconds stay at about 7 s or less (about 0.31 MB per second of video at 2.5 Mbps).
enum LatencyPreset: String, CaseIterable, Identifiable {
    case l0 = "L0"
    case l1 = "L1"
    case l2 = "L2"
    case l3 = "L3"

    /// L3: on a real TV (2026-11-21, build 13) the tester found L0 and L1 not smooth right
    /// after the broadcast starts (fine after a while) and L3 smooth at once. Delay was about the same (L0 4.0 s, L3 4.3 s).
    static let `default` = LatencyPreset.l3

    var id: String { rawValue }

    /// Short code for logs.
    var code: String { rawValue }

    var label: String {
        switch self {
        case .l0: return String(localized: "L0 (1초 조각, 목록 4개)")
        case .l1: return String(localized: "L1 (1초 조각, 목록 3개)")
        case .l2: return String(localized: "L2 (L1 + 시작 위치 끝에서 2초)")
        case .l3: return String(localized: "L3 기본 (0.5초 조각, 목록 6개)")
        }
    }

    /// The length the preset aims at (and its label shows).
    var nominalSegmentSeconds: Double {
        switch self {
        case .l0, .l1, .l2: return 1.0
        case .l3: return 0.5
        }
    }

    /// Actual segment length: the nominal one moved onto the grid both tracks share
    /// (`SegmentGrid`), so each segment holds whole video frames and whole AAC frames.
    /// L3: 16/30 s = 0.5333 s (16 frames, 25 AAC frames); L0-L2: 1.0667 s. Build 17 used exactly
    /// 0.5 s (23.4375 AAC frames) and the TV sound clicked about every segment (docs/PLAN.md "5. 소리").
    var segmentSeconds: Double { SegmentGrid.alignedSeconds(near: nominalSegmentSeconds) }

    /// Segments listed in the media playlist.
    var playlistWindow: Int {
        switch self {
        case .l0: return 4
        case .l1, .l2: return 3
        case .l3: return 6
        }
    }

    /// Segments kept in memory (a few more than the playlist, for slow clients).
    var storedSegments: Int {
        switch self {
        case .l0, .l1, .l2: return 6
        case .l3: return 10
        }
    }

    /// EXT-X-START TIME-OFFSET (negative: seconds before the end of the playlist), or nil for none.
    var startOffset: Double? {
        switch self {
        case .l2: return -2.0
        // L3: start 3 s (inside the 6-segment, 3.2 s first playlist) behind the newest segment. Build 16 startup trace: the TV
        // started only 1.5 s behind (seg2 while seg5 was newest) and fetched every segment about
        // 0.5 s after it appeared, so it had almost no buffer and stalled until it drifted back to
        // its steady ~2.4 s lag. Starting about there should skip that settling. -3.0 rather than
        // -2.5: RFC 8216 4.3.5.2 says a live offset SHOULD NOT be within 3 target durations (TD 1).
        case .l3: return -3.0
        case .l0, .l1: return nil
        }
    }

    /// Segments to wait for before the app tells the TV to play: enough for 3 s of video, so the
    /// first playlist the TV sees already meets the 3 x target duration rule (3 at 1.0667 s,
    /// 6 at 0.5333 s = 3.2 s).
    var segmentsBeforeReady: Int {
        min(playlistWindow, Int((3.0 / segmentSeconds).rounded(.up)))
    }

    /// Unknown or missing stored values fall back to the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(LatencyPreset.init(rawValue:)) ?? .default
    }

    /// Set once an earlier choice has been cleared. First reset 2026-11-21 (key "latencyPresetResetToL3":
    /// the latency experiment ended and L3 became the default, but testers' phones still kept the
    /// L0/L1 they had picked). Second reset from build 17: the app no longer offers the picker
    /// (AdvancedView), so a value picked in builds 16 and earlier would otherwise stay for good.
    static let l3ResetKey = "latencyPresetResetToL3.build17"

    static func load(from defaults: UserDefaults? = AppGroup.defaults) -> LatencyPreset {
        if let defaults, !defaults.bool(forKey: l3ResetKey) {
            defaults.removeObject(forKey: AppGroup.latencyPresetKey)
            defaults.set(true, forKey: l3ResetKey)
        }
        return LatencyPreset(storedValue: defaults?.string(forKey: AppGroup.latencyPresetKey))
    }

    /// A choice saved from now on is kept (the one-time reset is marked done).
    func save(to defaults: UserDefaults? = AppGroup.defaults) {
        defaults?.set(rawValue, forKey: AppGroup.latencyPresetKey)
        defaults?.set(true, forKey: Self.l3ResetKey)
    }
}
