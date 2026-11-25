import AVFoundation
import CoreGraphics

// All mutations before finish() are confined to the capture queue.
final class Recording {
    static let header = "record_index,source_pts_value,source_pts_timescale,source_pts_seconds,writer_pts_seconds,accepted_by_writer,reason\n"
    let folder: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let csv: FileHandle
    private var csvBuffer = Data()
    private var encoderBuffers: EncoderBuffers?
    private var metadata: Metadata
    private var origin: CMTime?
    private var lastAccepted: CMTime?
    private var lastDuration: CMTime = .invalid
    private var accepted: [FrameTime] = []
    private var index = 0
    private var failure: String?

    init(take: Take, role: DeviceRole, view: Viewpoint, mode: CameraMode,
         camera: CameraSettings, iosVersion: String, store: SessionStore = .local) throws {
        let device = SessionStore.deviceID
        let folder = try store.createTake(take, device: device, view: view)
        self.folder = folder
        metadata = Metadata(sessionID: take.sessionID, takeID: take.takeID, deviceID: device, deviceRole: role,
                            viewType: view, subjectID: take.subjectID, throwNumber: take.throwNumber,
                            throwingHand: take.throwingHand, deviceModel: SessionStore.deviceModel,
                            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                            iosVersion: iosVersion, selectedFormat: mode, cameraSettings: camera,
                            frameCount: 0, dropCount: 0, status: "preparing")
        writer = try AVAssetWriter(outputURL: folder.appending(path: "original.mov"), fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(mode.width),
            AVVideoHeightKey: Int(mode.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: mode.fps,
                AVVideoAverageBitRateKey: mode.width >= 1920 ? 80_000_000 : 30_000_000
            ]
        ])
        input.transform = CGAffineTransform(rotationAngle: CGFloat(camera.rotationDegrees) * .pi / 180)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.message("動画のエンコーダーを使用できません") }
        writer.add(input)
        let csvURL = folder.appending(path: "frame_timestamps.csv")
        try Data(Self.header.utf8).write(to: csvURL)
        csv = try FileHandle(forWritingTo: csvURL)
        try csv.seekToEnd()
        try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))
        log(CaptureEvent(kind: "armed", detail: mode.label))
    }

    func log(_ event: CaptureEvent) {
        do { try SessionStore.log(event, to: folder) }
        catch { failure = failure ?? error.localizedDescription }
    }

    func receive(_ sample: CMSampleBuffer) -> String? {
        let pts = sample.presentationTimeStamp
        guard pts.isNumeric else {
            row(pts, written: false, reason: "invalid_pts")
            return failure
        }
        if origin == nil {
            // The capture clock's integer timescale also preserves exact MOV sample intervals.
            input.mediaTimeScale = pts.timescale
            writer.movieTimeScale = pts.timescale
            guard writer.startWriting() else {
                failure = writer.error?.localizedDescription ?? "録画を開始できません"
                row(pts, written: false, reason: "writer_start_failed")
                return failure
            }
            writer.startSession(atSourceTime: .zero)
            origin = pts
        }
        var reason = ""
        if let lastAccepted, pts <= lastAccepted {
            reason = "non_increasing_pts"
        } else if writer.status != .writing {
            reason = "writer_failed"
            failure = writer.error?.localizedDescription ?? "動画の保存に失敗しました"
        } else if !input.isReadyForMoreMediaData {
            reason = "writer_backpressure"
        } else {
            do {
                guard let image = sample.imageBuffer else {
                    throw CaptureError.message("カメラサンプルに映像がありません")
                }
                if encoderBuffers == nil { encoderBuffers = try EncoderBuffers(source: image) }
                let timestamp = CMTimeSubtract(pts, origin ?? pts)
                if let timedSample = try encoderBuffers?.sample(from: image, timestamp: timestamp) {
                    if input.append(timedSample) {
                        accepted.append(FrameTime(pts))
                        lastAccepted = pts
                        lastDuration = sample.duration
                    } else {
                        reason = "writer_append_failed"
                        failure = writer.error?.localizedDescription ?? "フレームの保存に失敗しました"
                    }
                } else {
                    reason = "encoder_pool_full"
                }
            } catch {
                reason = "encoder_buffer_failed"
                failure = error.localizedDescription
            }
        }
        row(pts, written: reason.isEmpty, reason: reason)
        return failure
    }

    func dropped(_ sample: CMSampleBuffer) {
        let reason = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String ?? "capture_drop"
        row(sample.presentationTimeStamp, written: false, reason: reason)
    }

    private func row(_ pts: CMTime, written: Bool, reason: String) {
        let source = pts.isNumeric ? String(pts.seconds) : ""
        let relative = written ? origin.map { String(CMTimeSubtract(pts, $0).seconds) } ?? "" : ""
        let line = "\(index),\(pts.value),\(pts.timescale),\(source),\(relative),\(written),\(reason)\n"
        index += 1
        if !written { metadata.dropCount += 1 }
        csvBuffer.append(contentsOf: line.utf8)
        if csvBuffer.count >= 16_384 { flushCSV() }
    }

    private func flushCSV() {
        do { try csv.write(contentsOf: csvBuffer) }
        catch { failure = failure ?? error.localizedDescription }
        csvBuffer.removeAll(keepingCapacity: true)
    }

    func finish(partialReason: String?) async -> String? {
        failure = failure ?? partialReason
        log(CaptureEvent(kind: "finishing", detail: failure ?? "stop"))
        flushCSV()
        do { try csv.close() }
        catch { failure = failure ?? error.localizedDescription }
        if writer.status == .writing, let lastAccepted, let origin {
            let duration = lastDuration.isNumeric && lastDuration > .zero
                ? lastDuration : CMTime(value: 1, timescale: Int32(metadata.selectedFormat.fps))
            writer.endSession(atSourceTime: CMTimeAdd(CMTimeSubtract(lastAccepted, origin), duration))
            input.markAsFinished()
            await writer.finishWriting()
        } else if writer.status == .writing {
            writer.cancelWriting()
        }
        if writer.status != .completed {
            failure = failure ?? writer.error?.localizedDescription ?? "保存できたフレームがありません"
        } else if let origin {
            do {
                var (properties, movie) = try await VideoFrames.inspect(folder.appending(path: "original.mov"))
                properties.ptsMatch = VideoFrames.matches(source: accepted, movie: movie, origin: origin)
                metadata.actualVideoProperties = properties
                log(CaptureEvent(kind: "video_verification",
                                 detail: "writer=\(accepted.count), mov=\(movie.count), pts_match=\(properties.ptsMatch)"))
                if !properties.ptsMatch {
                    let mismatch = zip(accepted, movie).enumerated().first {
                        CMTimeSubtract($0.element.0.time, origin) != $0.element.1.time
                    }
                    if let mismatch {
                        let (source, saved) = mismatch.element
                        let expected = FrameTime(CMTimeSubtract(source.time, origin))
                        log(CaptureEvent(kind: "pts_mismatch",
                                         detail: "frame=\(mismatch.offset) expected=\(expected.value)/\(expected.timescale) actual=\(saved.value)/\(saved.timescale)"))
                    }
                    failure = failure ?? "動画とCSVのフレーム時刻が一致しません"
                }
            } catch { failure = failure ?? error.localizedDescription }
        }
        log(CaptureEvent(kind: failure == nil ? "saved" : "partial", detail: failure ?? "completed"))
        metadata.frameCount = accepted.count
        metadata.status = failure == nil ? "saved" : "partial"
        metadata.error = failure
        do { try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json")) }
        catch { failure = failure ?? error.localizedDescription }
        return failure
    }
}
