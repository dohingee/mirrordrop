import Foundation

/// Where the phone's app sound should come out while mirroring, chosen on the main screen and
/// read by the extension during a broadcast (stored in the App Group as `rawValue`).
/// The TV stream always carries an audio track; `.phone` fills it with silence, so switching
/// works live without restarting the encoder. The app cannot silence the phone itself (no public
/// API), so "TV only" means: the TV gets the sound and the user turns the phone volume down.
enum AudioOutput: String, CaseIterable, Identifiable {
    case tv
    case phone

    /// TV, like AirPlay: the sound follows the picture.
    static let `default` = AudioOutput.tv

    var id: String { rawValue }

    /// Short code for logs and the status.
    var code: String { rawValue }

    /// Picker label on the main screen (localized; "TV" is the same in both languages).
    var label: String {
        switch self {
        case .tv: return "TV"
        case .phone: return String(localized: "휴대폰")
        }
    }

    /// True when the TV stream should carry the real app sound (otherwise silence).
    var sendsSoundToTV: Bool { self == .tv }

    /// Unknown or missing stored values fall back to the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(AudioOutput.init(rawValue:)) ?? .default
    }

    static func load(from defaults: UserDefaults? = AppGroup.defaults) -> AudioOutput {
        AudioOutput(storedValue: defaults?.string(forKey: AppGroup.audioOutputKey))
    }

    func save(to defaults: UserDefaults? = AppGroup.defaults) {
        defaults?.set(rawValue, forKey: AppGroup.audioOutputKey)
    }

    /// Tells a running extension to re-read the setting at once (it also polls every 0.5 s).
    static func postChanged() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroup.audioOutputNotification as CFString),
            nil, nil, true)
    }

    /// Removes settings of earlier builds that nothing reads any more.
    static func removeLegacySettings(from defaults: UserDefaults? = AppGroup.defaults) {
        for key in AppGroup.legacyKeys { defaults?.removeObject(forKey: key) }
    }
}
