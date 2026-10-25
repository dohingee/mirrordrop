import AVFoundation
import UniformTypeIdentifiers

protocol HLSSegmenterDelegate: AnyObject {
    func segmenter(_ segmenter: HLSSegmenter, didOutputInitSegment data: Data)
    func segmenter(_ segmenter: HLSSegmenter, didOutputSegment data: Data, duration: Double)
    func segmenter(_ segmenter: HLSSegmenter, didFail message: String)
}

/// H.264 (+ optional AAC) encoder that emits fMP4 HLS segments in memory via AVAssetWriterDelegate.
/// Nothing is written to disk.
final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    struct Config {
        var width = 1280
        var height = 720
        var frameRate = 30
        var bitRate = 2_500_000
        var segmentSeconds = 1.0
        var includeAudio = false
    }

    let config: Config
    weak var delegate: HLSSegmenterDelegate?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var failed = false

    init(config: Config) {
        self.config = config
    }

    var isRunning: Bool { writer?.status == .writing }

    /// Returns false when the frame was not taken (encoder busy, out-of-order time, or failure).
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        if writer == nil, !failed { start(at: time) }
        guard let writer, writer.status == .writing, let videoInput, let adaptor else {
            reportFailureIfNeeded()
            return false
        }
        if lastVideoTime.isValid, time <= lastVideoTime { return false }
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            reportFailureIfNeeded()
            return false
        }
        lastVideoTime = time
        return true
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData,
              sessionStart.isValid, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= sessionStart
        else { return }
        if !audioInput.append(sampleBuffer) { reportFailureIfNeeded() }
    }

    func finish(completion: @escaping () -> Void) {
        guard let writer, writer.status == .writing else { completion(); return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    private func start(at time: CMTime) {
        guard let contentType = UTType(AVFileType.mp4.rawValue) else { fail("mp4 UTType missing"); return }
        let writer = AVAssetWriter(contentType: contentType)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: config.segmentSeconds, preferredTimescale: 1000)
        writer.initialSegmentStartTime = time
        writer.delegate = self

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitRate,
            AVVideoExpectedSourceFrameRateKey: config.frameRate,
            AVVideoMaxKeyFrameIntervalKey: config.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: config.segmentSeconds,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { fail("cannot add video input"); return }
        writer.add(video)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

        var audio: AVAssetWriterInput?
        if config.includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            } else {
                delegate?.segmenter(self, didFail: "cannot add audio input; continuing video-only")
            }
        }

        guard writer.startWriting() else {
            fail("startWriting: \(writer.error?.localizedDescription ?? "unknown")")
            return
        }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        self.videoInput = video
        self.adaptor = adaptor
        self.audioInput = audio
        sessionStart = time
    }

    private func reportFailureIfNeeded() {
        guard let writer, writer.status == .failed, !failed else { return }
        fail("writer failed: \(writer.error?.localizedDescription ?? "unknown") \((writer.error as NSError?)?.code ?? 0)")
    }

    private func fail(_ message: String) {
        failed = true
        delegate?.segmenter(self, didFail: message)
    }

    // MARK: AVAssetWriterDelegate (called on the writer's own queue)

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            delegate?.segmenter(self, didOutputInitSegment: segmentData)
        case .separable:
            let videoReport = segmentReport?.trackReports.first { $0.mediaType == .video }
            let seconds = videoReport?.duration.seconds ?? config.segmentSeconds
            let duration = seconds.isFinite && seconds > 0 ? seconds : config.segmentSeconds
            delegate?.segmenter(self, didOutputSegment: segmentData, duration: duration)
        @unknown default:
            break
        }
    }
}
