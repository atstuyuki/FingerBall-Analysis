import AVFoundation

enum CaptureError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

enum VideoFrames {
    static func inspect(_ url: URL) async throws -> (VideoProperties, [FrameTime]) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CaptureError.message("動画トラックがありません")
        }
        let size = try await track.load(.naturalSize)
        let fps = try await track.load(.nominalFrameRate)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw CaptureError.message("動画を検査できません") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CaptureError.message("動画を読み込めません") }
        var frames: [FrameTime] = []
        while let sample = output.copyNextSampleBuffer() {
            // A MOV reader can also emit zero-sample timeline markers.
            guard sample.numSamples > 0 else { continue }
            frames.append(FrameTime(sample.presentationTimeStamp))
        }
        guard reader.status == .completed else {
            throw reader.error ?? CaptureError.message("動画の検査が中断されました")
        }
        frames.sort { $0.time < $1.time }
        return (VideoProperties(width: Int(abs(size.width)), height: Int(abs(size.height)),
                                nominalFPS: fps, frameCount: frames.count, ptsMatch: false), frames)
    }

    static func matches(source: [FrameTime], movie: [FrameTime], origin: CMTime) -> Bool {
        source.count == movie.count && zip(source, movie).allSatisfy { accepted, saved in
            CMTimeSubtract(accepted.time, origin) == saved.time
        }
    }
}
