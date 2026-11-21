import AVFoundation
import UniformTypeIdentifiers

protocol HLSSegmenterDelegate: AnyObject {
    func segmenter(_ segmenter: HLSSegmenter, didOutputInitSegment data: Data)
    func segmenter(_ segmenter: HLSSegmenter, didOutputSegment data: Data, duration: Double)
    /// The writer is dead; the owner should replace this segmenter.
    func segmenter(_ segmenter: HLSSegmenter, didFail message: String)
    /// Something went wrong but encoding goes on.
    func segmenter(_ segmenter: HLSSegmenter, didWarn message: String)
}

/// H.264 + AAC encoder that emits fMP4 HLS segments in memory via AVAssetWriterDelegate.
/// Nothing is written to disk.
final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    struct Config {
        var width = 1280
        var height = 720
        var frameRate = SegmentGrid.frameRate
        var bitRate = 2_500_000
        /// Should be on the shared grid (`SegmentGrid.alignedSeconds`, as LatencyPreset gives it);
        /// it is used as a whole number of video frames.
        var segmentSeconds = SegmentGrid.alignedSeconds(near: 1.0)
        /// The audio track is always there (silence when there is no sound or the output is the
        /// phone), so the TV setting can change live. See AudioTrack and docs/PLAN.md "5. 소리".
        var includeAudio = true
    }

    let config: Config
    weak var delegate: HLSSegmenterDelegate?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var sessionStart = CMTime.invalid
    private var failed = false
    /// Video frame times on the 1/frameRate grid (see SegmentGrid.swift for why).
    private var frameGrid: VideoFrameGrid
    /// Grid ticks (SegmentGrid.timescale) per video frame: 1600 at 30 fps and 48 kHz.
    private let ticksPerFrame: Int64
    /// The last frame the encoder took, repeated on a segment boundary the frames skipped over.
    /// It is the same buffer MirrorPipeline keeps as `lastFrame`, so it adds no pool buffer normally.
    private var lastPixelBuffer: CVPixelBuffer?

    init(config: Config) {
        self.config = config
        frameGrid = VideoFrameGrid(framesPerSegment: SegmentGrid.framesPerSegment(
            seconds: config.segmentSeconds, frameRate: config.frameRate))
        ticksPerFrame = Int64(max(1, SegmentGrid.timescale / max(1, config.frameRate)))
    }

    /// Exact segment interval on the grid (16 frames = 25600/48000 s for L3).
    private var segmentInterval: CMTime {
        CMTime(value: Int64(frameGrid.framesPerSegment) * ticksPerFrame, timescale: CMTimeScale(SegmentGrid.timescale))
    }

    private func gridTime(_ index: Int64) -> CMTime {
        CMTime(value: sessionStart.value + index * ticksPerFrame, timescale: sessionStart.timescale)
    }

    var isRunning: Bool { writer?.status == .writing }

    /// Source time of the first video frame (the session start), or invalid before it.
    var sessionStartTime: CMTime { sessionStart }

    /// True once the writer runs with an audio track (audio before that is not taken).
    var acceptsAudio: Bool { writer?.status == .writing && audioInput != nil && sessionStart.isValid }

    /// Returns false when the frame was not taken (encoder busy, out-of-order time, no free grid
    /// slot near its time, or failure). The frame is written at its 1/frameRate grid time, not `time`.
    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        // The session starts on the grid's time scale so every frame, audio sample and segment
        // boundary is an exact whole number of ticks.
        if writer == nil, !failed {
            start(at: time.convertScale(CMTimeScale(SegmentGrid.timescale), method: .roundHalfAwayFromZero))
        }
        guard let writer, writer.status == .writing, let videoInput, let adaptor, sessionStart.isValid else {
            reportFailureIfNeeded()
            return false
        }
        let exact = (time - sessionStart).seconds * Double(config.frameRate)
        guard let placement = frameGrid.place(exactIndex: exact) else { return false }
        guard videoInput.isReadyForMoreMediaData else { return false }
        // Repeat the previous frame on any segment boundary this frame skips, so the writer cuts there.
        if let previous = lastPixelBuffer {
            for boundary in placement.fillers {
                guard videoInput.isReadyForMoreMediaData else { break }
                guard adaptor.append(previous, withPresentationTime: gridTime(boundary)) else {
                    reportFailureIfNeeded()
                    return false
                }
                frameGrid.didAppend(boundary)
            }
        }
        guard videoInput.isReadyForMoreMediaData else { return false }
        guard adaptor.append(pixelBuffer, withPresentationTime: gridTime(placement.index)) else {
            reportFailureIfNeeded()
            return false
        }
        frameGrid.didAppend(placement.index)
        lastPixelBuffer = pixelBuffer
        return true
    }

    /// Returns false when the buffer was not taken (no audio track, encoder busy, too early, failure).
    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData,
              sessionStart.isValid, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= sessionStart
        else { return false }
        guard audioInput.append(sampleBuffer) else {
            reportFailureIfNeeded()
            return false
        }
        return true
    }

    func finish(completion: @escaping () -> Void) {
        lastPixelBuffer = nil
        guard let writer, writer.status == .writing else { completion(); return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    private func start(at time: CMTime) {
        guard let contentType = UTType(AVFileType.mp4.rawValue) else { fail("mp4 UTType missing"); return }
        let writer = AVAssetWriter(contentType: contentType)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        // Exact (16 frames = 25 AAC frames for L3). In encoding mode the writer makes the frame that
        // reaches the interval a sync sample and cuts there (WWDC 2020 "Author fragmented MPEG-4
        // content with AVAssetWriter"); with frames on the grid that frame sits exactly on it.
        let interval = segmentInterval
        writer.preferredOutputSegmentInterval = interval
        writer.initialSegmentStartTime = time
        writer.delegate = self

        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.bitRate,
            AVVideoExpectedSourceFrameRateKey: config.frameRate,
            // One keyframe per segment: frames per segment (16 for L3).
            AVVideoMaxKeyFrameIntervalKey: frameGrid.framesPerSegment,
            AVVideoMaxKeyFrameIntervalDurationKey: interval.seconds,
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
                AVSampleRateKey: AudioTrackFormat.sampleRate,
                AVNumberOfChannelsKey: AudioTrackFormat.channels,
                AVEncoderBitRateKey: AudioTrackFormat.bitRate,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            } else {
                delegate?.segmenter(self, didWarn: "cannot add audio input; continuing video-only")
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
