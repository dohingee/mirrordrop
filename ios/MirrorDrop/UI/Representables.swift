import GoogleCast
import ReplayKit
import SwiftUI

/// Google's Cast button: shows discovered devices and connects/disconnects.
struct CastButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        button.tintColor = .tintColor
        return button
    }

    func updateUIView(_ uiView: GCKUICastButton, context: Context) {}
}

/// System broadcast picker limited to our own extension. The picker's own button is what opens
/// the system broadcast sheet, so it stays on top and is stretched to the whole view: a tap
/// anywhere on the (large) card below it reaches the picker itself.
/// `onTap` runs after a completed tap on it (the picker still opens its sheet as before).
struct BroadcastPickerView: UIViewRepresentable {
    var glyphColor: UIColor = .tintColor
    var onTap: (() -> Void)?

    func makeUIView(context: Context) -> FullSizeBroadcastPicker {
        let picker = FullSizeBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = AppGroup.broadcastExtensionID
        picker.showsMicrophoneButton = false
        picker.glyphColor = glyphColor
        picker.onTap = onTap
        return picker
    }

    func updateUIView(_ uiView: FullSizeBroadcastPicker, context: Context) {
        uiView.glyphColor = glyphColor
        uiView.onTap = onTap
    }
}

final class FullSizeBroadcastPicker: RPSystemBroadcastPickerView {
    var glyphColor: UIColor = .tintColor {
        didSet { setNeedsLayout() }
    }

    /// Called on touch-up inside the picker's button (MirrorDrop's stop card: StopAlertCenter.noteUserStopTap).
    var onTap: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // Public UIView/UIButton API only: resize the picker's button and tint its glyph.
        for case let button as UIButton in subviews {
            button.frame = bounds
            button.tintColor = glyphColor
            button.imageView?.tintColor = glyphColor
            // An extra target next to the picker's own one: both run, the sheet still opens. Adding the
            // same target-action pair again is a no-op (UIControl), so this is safe on every layout pass.
            button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
        }
    }

    @objc private func buttonTapped() {
        onTap?()
    }
}
