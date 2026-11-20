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
        case .l0: return "L0 (1초 조각, 목록 4개)"
        case .l1: return "L1 (1초 조각, 목록 3개)"
        case .l2: return "L2 (L1 + 시작 위치 끝에서 2초)"
        case .l3: return "L3 기본 (0.5초 조각, 목록 6개)"
        }
    }

    var segmentSeconds: Double {
        switch self {
        case .l0, .l1, .l2: return 1.0
        case .l3: return 0.5
        }
    }

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
        case .l0: return 7
        case .l1, .l2: return 6
        case .l3: return 10
        }
    }

    /// EXT-X-START TIME-OFFSET (negative: seconds before the end of the playlist), or nil for none.
    var startOffset: Double? {
        switch self {
        case .l2: return -2.0
        case .l0, .l1, .l3: return nil
        }
    }

    /// Segments to wait for before the app tells the TV to play: enough for 3 s of video, so the
    /// first playlist the TV sees already meets the 3 x target duration rule (3 at 1 s, 6 at 0.5 s).
    var segmentsBeforeReady: Int {
        min(playlistWindow, Int((3.0 / segmentSeconds).rounded(.up)))
    }

    /// Unknown or missing stored values fall back to the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(LatencyPreset.init(rawValue:)) ?? .default
    }

    static func load(from defaults: UserDefaults? = AppGroup.defaults) -> LatencyPreset {
        LatencyPreset(storedValue: defaults?.string(forKey: AppGroup.latencyPresetKey))
    }

    func save(to defaults: UserDefaults? = AppGroup.defaults) {
        defaults?.set(rawValue, forKey: AppGroup.latencyPresetKey)
    }
}
