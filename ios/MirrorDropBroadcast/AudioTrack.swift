import AVFoundation
import CoreMedia

/// Builds the TV stream's audio track: ReplayKit app sound normalised to 48 kHz stereo Int16,
/// placed on the video timeline with continuous timestamps, and silence wherever real sound is
/// missing (nothing playing, paused) or the output is the phone (real sound replaced by zeros).
/// The timing and format decisions are pure logic in Shared/AudioFill.swift (unit-tested).
/// Not thread-safe: used only on MirrorPipeline's queue. Memory: no queues; each buffer is
/// converted and handed to the encoder at once, or dropped.
final class AudioTrack {
    struct Stats {
        var samplesIn = 0
        var silentFrames = 0
        var realFrames = 0
        var droppedFrames = 0
        var peakRecent: Float = 0
        var peakMax: Float = 0
        var sourceFormat: String?
    }

    var output: AudioOutput
    private(set) var stats = Stats()
    private let log: (String) -> Void
    private let formatDescription: CMAudioFormatDescription?
    /// Track timeline of the current encoder; a new encoder (recovery) starts a new one.
    private var timeline: AudioTimeline?
    private var timelineStart = CMTime.invalid
    private var timelineOwner: ObjectIdentifier?
    private var mapper = AudioClockMapper()
    private var resampler: StereoResampler?
    private var sourceFormat: PCMSourceFormat?
    private var lastRealHostSeconds: Double?
    private var unsupportedLogged = false
    /// Shared zeros for silence buffers (0.1 s of stereo Int16, about 19 KB).
    private let zeros = [Int16](repeating: 0, count: AudioTrackFormat.maxFramesPerBuffer * AudioTrackFormat.channels)
    private static let sampleRate = Double(AudioTrackFormat.sampleRate)
    /// At most this much silence per call, so one call never does a lot of work.
    private static let maxSilencePerCall = AudioTrackFormat.sampleRate * 2

    init(output: AudioOutput, log: @escaping (String) -> Void) {
        self.output = output
        self.log = log
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * AudioTrackFormat.channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * AudioTrackFormat.channels),
            mChannelsPerFrame: UInt32(AudioTrackFormat.channels),
            mBitsPerChannel: 16,
            mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        formatDescription = status == noErr ? description : nil
        if formatDescription == nil { log("ERROR audio format description failed (\(status))") }
    }

    /// Loudest real sample since the last call (for the "about the last second" level).
    func takeRecentPeak() -> Float {
        let peak = stats.peakRecent
        stats.peakRecent = 0
        return peak
    }

    /// Every pipeline tick: keeps the track up with the video using silence when no real sound comes.
    func fill(videoNow: Double, hostNow: Double, segmenter: HLSSegmenter) {
        guard prepareTimeline(for: segmenter), let timeline else { return }
        let since = lastRealHostSeconds.map { hostNow - $0 }
        let frames = timeline.silenceToFill(videoTime: videoNow, secondsSinceRealAudio: since)
        if frames > 0 { writeSilence(frames, to: segmenter) }
    }

    /// A ReplayKit `.audioApp` buffer. `muted` (paused) writes it as silence like the phone output.
    func handleReal(_ sampleBuffer: CMSampleBuffer, videoNow: Double, hostNow: Double, paused: Bool,
                    segmenter: HLSSegmenter) {
        stats.samplesIn += 1
        lastRealHostSeconds = hostNow
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }
        guard let format = Self.format(of: sampleBuffer), format.isSupported else {
            stats.droppedFrames += frameCount
            if !unsupportedLogged {
                unsupportedLogged = true
                log("ERROR app audio format not readable: \(Self.format(of: sampleBuffer)?.summary ?? "not linear PCM")")
            }
            return
        }
        if format != sourceFormat {
            sourceFormat = format
            resampler = StereoResampler(inputRate: format.sampleRate)
            stats.sourceFormat = format.summary
            log("app audio format \(format.summary)")
        }
        guard let decoded = Self.decode(sampleBuffer, format: format, frames: frameCount) else {
            stats.droppedFrames += frameCount
            return
        }
        let peak = PCMDecoder.peak(decoded.left, decoded.right)
        stats.peakRecent = max(stats.peakRecent, peak)
        stats.peakMax = max(stats.peakMax, peak)
        guard var resampler else { return }
        let converted = resampler.process(left: decoded.left, right: decoded.right)
        self.resampler = resampler
        let muted = paused || !output.sendsSoundToTV
        let samples = PCMEncoder.interleavedInt16(left: converted.left, right: converted.right, muted: muted)
        let frames = converted.left.count
        guard frames > 0 else { return }

        guard prepareTimeline(for: segmenter), let timeline else {
            stats.droppedFrames += frames
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let mapped = pts.isValid ? mapper.map(pts.seconds, videoNow: videoNow) : (time: timeline.endTime, resynced: false)
        if mapped.resynced {
            log(String(format: "app audio clock re-anchored (offset %.3f s)", mapper.offset))
        }
        let placement = timeline.place(time: mapped.time, frames: frames)
        if placement.silenceBefore > 0 {
            writeSilence(min(placement.silenceBefore, Int(Self.sampleRate)), to: segmenter)
        }
        let skip = min(placement.skip, frames)
        stats.droppedFrames += skip
        guard skip < frames else { return }
        let written = write(samples[(skip * 2)...], to: segmenter)
        stats.realFrames += written
        stats.droppedFrames += frames - skip - written
    }

    // MARK: Internals

    /// Starts a timeline at the session start of a new encoder. False until it accepts audio.
    private func prepareTimeline(for segmenter: HLSSegmenter) -> Bool {
        let owner = ObjectIdentifier(segmenter)
        if timelineOwner == owner, timeline != nil { return true }
        guard segmenter.acceptsAudio else { return false }
        // On the 48 kHz grid (SegmentGrid), so the track starts exactly with the video and every
        // segment boundary falls on a whole sample (and, with the grid length, a whole AAC frame).
        let start = segmenter.sessionStartTime
        timeline = AudioTimeline(start: start.seconds)
        timelineStart = start
        timelineOwner = owner
        return true
    }

    private func writeSilence(_ frames: Int, to segmenter: HLSSegmenter) {
        var remaining = min(frames, Self.maxSilencePerCall)
        while remaining > 0 {
            let chunk = min(remaining, AudioTrackFormat.maxFramesPerBuffer)
            guard appendChunk(zeros[0..<(chunk * AudioTrackFormat.channels)], to: segmenter) else { return }
            stats.silentFrames += chunk
            remaining -= chunk
        }
    }

    /// Writes interleaved stereo samples in pieces; returns the frames the encoder took.
    private func write(_ samples: ArraySlice<Int16>, to segmenter: HLSSegmenter) -> Int {
        var written = 0
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(samples.endIndex, index + AudioTrackFormat.maxFramesPerBuffer * AudioTrackFormat.channels)
            guard appendChunk(samples[index..<end], to: segmenter) else { break }
            written += (end - index) / AudioTrackFormat.channels
            index = end
        }
        return written
    }

    /// One CMSampleBuffer at the track end. The track advances only when the encoder takes it.
    private func appendChunk(_ samples: ArraySlice<Int16>, to segmenter: HLSSegmenter) -> Bool {
        guard var timeline, let formatDescription, timelineStart.isValid else { return false }
        let frames = samples.count / AudioTrackFormat.channels
        guard frames > 0 else { return true }
        let bytes = frames * AudioTrackFormat.channels * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return false }
        status = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                                 dataLength: bytes)
        }
        guard status == kCMBlockBufferNoErr else { return false }
        let pts = timelineStart + CMTime(value: timeline.framesWritten, timescale: CMTimeScale(AudioTrackFormat.sampleRate))
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer, segmenter.appendAudio(sampleBuffer) else { return false }
        timeline.advance(by: frames)
        self.timeline = timeline
        return true
    }

    private static func format(of sampleBuffer: CMSampleBuffer) -> PCMSourceFormat? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM else { return nil }
        let flags = asbd.mFormatFlags
        return PCMSourceFormat(
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            isFloat: flags & kAudioFormatFlagIsFloat != 0,
            isBigEndian: flags & kAudioFormatFlagIsBigEndian != 0,
            isNonInterleaved: flags & kAudioFormatFlagIsNonInterleaved != 0)
    }

    private static func decode(_ sampleBuffer: CMSampleBuffer, format: PCMSourceFormat,
                               frames: Int) -> (left: [Float], right: [Float])? {
        var sizeNeeded = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded >= MemoryLayout<AudioBufferList>.size else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded,
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return nil }
        return withExtendedLifetime(block) {
            let buffers = UnsafeMutableAudioBufferListPointer(list).map {
                UnsafeRawBufferPointer(start: UnsafeRawPointer($0.mData), count: Int($0.mDataByteSize))
            }
            return PCMDecoder.decode(buffers, format: format, frames: frames)
        }
    }
}
