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
struct BroadcastPickerView: UIViewRepresentable {
    var glyphColor: UIColor = .tintColor

    func makeUIView(context: Context) -> FullSizeBroadcastPicker {
        let picker = FullSizeBroadcastPicker(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = AppGroup.broadcastExtensionID
        picker.showsMicrophoneButton = false
        picker.glyphColor = glyphColor
        return picker
    }

    func updateUIView(_ uiView: FullSizeBroadcastPicker, context: Context) {
        uiView.glyphColor = glyphColor
    }
}

final class FullSizeBroadcastPicker: RPSystemBroadcastPickerView {
    var glyphColor: UIColor = .tintColor {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Public UIView/UIButton API only: resize the picker's button and tint its glyph.
        for case let button as UIButton in subviews {
            button.frame = bounds
            button.tintColor = glyphColor
            button.imageView?.tintColor = glyphColor
        }
    }
}
