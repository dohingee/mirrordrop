import ReplayKit

/// Broadcast Upload Extension entry point. Memory budget is ~50 MB, so all work is done
/// with fixed-size pools and a small in-memory segment window (see MirrorPipeline).
final class SampleHandler: RPBroadcastSampleHandler {
    private let pipeline = MirrorPipeline()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            try pipeline.start()
        } catch {
            finishBroadcastWithError(error)
        }
    }

    override func broadcastPaused() {
        pipeline.setPaused(true)
    }

    override func broadcastResumed() {
        pipeline.setPaused(false)
    }

    override func broadcastFinished() {
        pipeline.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            pipeline.handleVideo(sampleBuffer)
        case .audioApp:
            pipeline.handleAppAudio(sampleBuffer)
        case .audioMic:
            break
        @unknown default:
            break
        }
    }
}
