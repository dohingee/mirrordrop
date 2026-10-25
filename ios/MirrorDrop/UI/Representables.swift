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

/// System broadcast picker limited to our own extension.
struct BroadcastPickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        picker.preferredExtension = AppGroup.broadcastExtensionID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
