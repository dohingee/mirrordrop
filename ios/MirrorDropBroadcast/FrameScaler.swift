import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// Scales screen frames into a fixed landscape canvas (e.g. 1280x720) with black bars.
/// Landscape content arrives as a portrait buffer plus an orientation attachment, so it is
/// first fitted into a portrait canvas and then rotated.
final class FrameScaler {
    let width: Int
    let height: Int
    private let transfer: VTPixelTransferSession
    private let rotation: VTPixelRotationSession
    private let outputPool: CVPixelBufferPool
    private let portraitPool: CVPixelBufferPool
    private var currentRotation: String?
    /// Caps how many output buffers can be alive at once (memory budget).
    private let maxBuffers = 6

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height

        var transferSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == noErr,
              let transferSession else { return nil }
        VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
        transfer = transferSession

        var rotationSession: VTPixelRotationSession?
        guard VTPixelRotationSessionCreate(kCFAllocatorDefault, &rotationSession) == noErr,
              let rotationSession else { return nil }
        rotation = rotationSession

        guard let output = Self.makePool(width: width, height: height),
              let portrait = Self.makePool(width: height, height: width) else { return nil }
        outputPool = output
        portraitPool = portrait
    }

    deinit {
        VTPixelTransferSessionInvalidate(transfer)
        VTPixelRotationSessionInvalidate(rotation)
    }

    func scale(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let turn: CFString?
        switch orientation {
        // EXIF semantics: .right means the picture must be turned 90° clockwise to look upright.
        case .right, .rightMirrored: turn = kVTRotation_CW90
        case .left, .leftMirrored: turn = kVTRotation_CCW90
        default: turn = nil
        }

        guard let turn else {
            guard let output = makeBuffer(outputPool) else { return nil }
            Self.fillBlack(output)
            return VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr ? output : nil
        }

        guard let portrait = makeBuffer(portraitPool), let output = makeBuffer(outputPool) else { return nil }
        Self.fillBlack(portrait)
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: portrait) == noErr else { return nil }
        if currentRotation != turn as String {
            VTSessionSetProperty(rotation, key: kVTPixelRotationPropertyKey_Rotation, value: turn)
            currentRotation = turn as String
        }
        return VTPixelRotationSessionRotateImage(rotation, portrait, output) == noErr ? output : nil
    }

    /// Pooled buffers are reused, so clear the letterbox bars (video-range black: Y=16, CbCr=128).
    private static func fillBlack(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, plane == 0 ? 16 : 128, bytes)
        }
    }

    private func makeBuffer(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: maxBuffers] as CFDictionary
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, aux, &buffer)
        return result == kCVReturnSuccess ? buffer : nil
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 2]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &pool)
        return pool
    }
}
