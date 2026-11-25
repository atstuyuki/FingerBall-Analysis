import AVFoundation
import CoreGraphics

// The capture queue copies source surfaces. The processing queue encodes and writes them.
// Finish takes ownership after Capture detaches the writer and the processing queue drains.
final class Recording {
    static let header = "record_index,source_pts_value,source_pts_timescale,source_pts_seconds,writer_pts_seconds,accepted_by_writer,reason\n"
    let folder: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let encoder: HardwareEncoder
    private let spool: FrameSpool?
    private var staged: [PendingFrame] = []
    private var lastStaged: CMTime?
    private var stagedFrameCount = 0
    private let rotation: CGAffineTransform
    private struct PendingFrame {
        let pts: CMTime
        let duration: CMTime
        let dropReason: String?
    }
    private var pending: [Int: PendingFrame] = [:]
    private var nextToWrite = 0
    private var lastSubmitted: CMTime?
    private var encoded: HardwareEncoder.Result?
    private let processing = DispatchQueue(label: "org.fingerball.capture.encode", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    var onFailure: ((String) -> Void)?

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
        encoder = try HardwareEncoder(mode: mode)
        spool = mode.fps >= 120 ? try FrameSpool(folder: folder) : nil
        rotation = CGAffineTransform(rotationAngle: CGFloat(camera.rotationDegrees) * .pi / 180)
        let csvURL = folder.appending(path: "frame_timestamps.csv")
        try Data(Self.header.utf8).write(to: csvURL)
        csv = try FileHandle(forWritingTo: csvURL)
        try csv.seekToEnd()
        try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))
        log(CaptureEvent(kind: "armed", detail: mode.label + ", codec=" + encoder.codec))
    }

    func log(_ event: CaptureEvent) {
        processing.async { self.writeEvent(event) }
    }

    private func writeEvent(_ event: CaptureEvent) {
        do { try SessionStore.log(event, to: folder) }
        catch { failure = failure ?? error.localizedDescription }
    }

    func receive(_ sample: CMSampleBuffer) {
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        guard pts.isNumeric else {
            enqueueDrop(pts, reason: "invalid_pts")
            return
        }
        guard slots.wait(timeout: .now()) == .success else {
            enqueueDrop(pts, reason: "encoder_input_queue_full")
            return
        }
        do {
            guard let image = sample.imageBuffer else {
                throw CaptureError.message("カメラサンプルに映像がありません")
            }
            if encoderBuffers == nil { encoderBuffers = try EncoderBuffers(source: image) }
            guard let owned = try encoderBuffers?.copy(image) else {
                slots.signal()
                enqueueDrop(pts, reason: "encoder_pool_full")
                return
            }
            processing.async {
                defer { self.slots.signal() }
                if let spool = self.spool {
                    self.stage(owned, pts: pts, duration: duration, spool: spool)
                } else {
                    self.submit(owned, pts: pts, duration: duration)
                }
            }
        } catch {
            slots.signal()
            processing.async {
                self.recordFailure(error.localizedDescription)
                self.recordDroppedFrame(pts, reason: "capture_buffer_failed")
            }
        }
    }

    private func stage(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime, spool: FrameSpool) {
        var reason: String?
        if failure != nil {
            reason = "capture_aborting"
        } else if let lastStaged, pts <= lastStaged {
            reason = "non_increasing_pts"
        } else {
            do {
                try spool.append(image)
                stagedFrameCount += 1
                lastStaged = pts
            } catch {
                reason = "staging_write_failed"
                recordFailure(error.localizedDescription)
            }
        }
        staged.append(PendingFrame(pts: pts, duration: duration, dropReason: reason))
    }

    private func submit(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime, duringCapture: Bool = true) {
        drain()
        var reason: String?
        if duringCapture && failure != nil {
            reason = "capture_aborting"
        } else if let lastSubmitted, pts <= lastSubmitted {
            reason = "non_increasing_pts"
        } else if pending.count >= 64 {
            reason = "writer_queue_full"
            if pending.count >= 1_024 { recordFailure("MOVの書き込みが映像入力に追いつきません") }
        } else {
            do {
                if origin == nil { origin = pts }
                try encoder.submit(image, at: CMTimeSubtract(pts, origin ?? pts), index: index)
                lastSubmitted = pts
            } catch {
                reason = "encoder_submit_failed"
                recordFailure(error.localizedDescription)
            }
        }
        appendPending(pts, duration: duration, reason: reason)
    }

    func dropped(_ sample: CMSampleBuffer) {
        let reason = CMGetAttachment(sample, key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
                                     attachmentModeOut: nil) as? String ?? "capture_drop"
        enqueueDrop(sample.presentationTimeStamp, reason: reason)
    }

    private func enqueueDrop(_ pts: CMTime, reason: String) {
        processing.async { self.recordDroppedFrame(pts, reason: reason) }
    }

    private func recordDroppedFrame(_ pts: CMTime, reason: String) {
        if spool != nil {
            staged.append(PendingFrame(pts: pts, duration: .invalid, dropReason: reason))
        } else {
            drain()
            appendPending(pts, duration: .invalid, reason: reason)
            if pending.count >= 1_024 { recordFailure("MOVの書き込みが映像入力に追いつきません") }
        }
    }

    private func appendPending(_ pts: CMTime, duration: CMTime, reason: String?) {
        pending[index] = PendingFrame(pts: pts, duration: duration, dropReason: reason)
        index += 1
    }

    private func recordFailure(_ message: String) {
        guard failure == nil else { return }
        failure = message
        onFailure?(message)
    }

    private func startWriter(with sample: CMSampleBuffer) throws -> AVAssetWriterInput {
        if let input { return input }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: sample.formatDescription)
        input.transform = rotation
        input.mediaTimeScale = origin?.timescale ?? sample.presentationTimeStamp.timescale
        writer.movieTimeScale = input.mediaTimeScale
        guard writer.canAdd(input) else { throw CaptureError.message("MOVに圧縮動画を追加できません") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.message("MOVを作成できません")
        }
        writer.startSession(atSourceTime: .zero)
        self.input = input
        return input
    }

    private func drain(finishing: Bool = false, deadline: Date = .distantPast) {
        while let frame = pending[nextToWrite] {
            if let reason = frame.dropReason {
                writeRow(frame.pts, written: false, reason: reason)
                continue
            }
            if encoded == nil { encoded = encoder.takeResult(at: nextToWrite) }
            guard let result = encoded else {
                if !finishing { return }
                writeRow(frame.pts, written: false, reason: "encoder_no_output")
                continue
            }
            guard result.status == noErr, let sample = result.sample else {
                encoded = nil
                writeRow(frame.pts, written: false, reason: "encoder_drop_\(result.status)")
                continue
            }
            do {
                let input = try startWriter(with: sample)
                if !input.isReadyForMoreMediaData && writer.status == .writing {
                    if !finishing || Date() < deadline { return }
                    throw CaptureError.message("MOVの書き込みがタイムアウトしました")
                }
                guard input.append(sample) else {
                    throw writer.error ?? CaptureError.message("MOVにフレームを書き込めません")
                }
                accepted.append(FrameTime(frame.pts))
                lastAccepted = frame.pts
                lastDuration = frame.duration
                writeRow(frame.pts, written: true, reason: "")
            } catch {
                recordFailure(error.localizedDescription)
                writeRow(frame.pts, written: false, reason: "writer_append_failed")
            }
            encoded = nil
        }
    }

    private func writeRow(_ pts: CMTime, written: Bool, reason: String) {
        let source = pts.isNumeric ? String(pts.seconds) : ""
        let relative = written ? origin.map { String(CMTimeSubtract(pts, $0).seconds) } ?? "" : ""
        let line = "\(nextToWrite),\(pts.value),\(pts.timescale),\(source),\(relative),\(written),\(reason)\n"
        pending.removeValue(forKey: nextToWrite)
        nextToWrite += 1
        if !written { metadata.dropCount += 1 }
        csvBuffer.append(contentsOf: line.utf8)
        if csvBuffer.count >= 16_384 { flushCSV() }
    }

    private func flushCSV() {
        do { try csv.write(contentsOf: csvBuffer) }
        catch { recordFailure(error.localizedDescription) }
        csvBuffer.removeAll(keepingCapacity: true)
    }

    private func encodeStagedFrames(_ spool: FrameSpool) async {
        do {
            try spool.rewind()
            for frame in staged {
                if let reason = frame.dropReason {
                    appendPending(frame.pts, duration: frame.duration, reason: reason)
                    drain()
                    continue
                }
                let deadline = Date().addingTimeInterval(5)
                var image = try encoderBuffers?.allocate()
                while (image == nil || pending.count >= 48) && Date() < deadline {
                    drain()
                    if image == nil { image = try encoderBuffers?.allocate() }
                    if image == nil || pending.count >= 48 { try await Task.sleep(for: .milliseconds(3)) }
                }
                guard let image, pending.count < 48 else {
                    throw CaptureError.message("一時保存の映像をMOVへ変換できません")
                }
                try spool.read(into: image)
                submit(image, pts: frame.pts, duration: frame.duration, duringCapture: false)
            }
        } catch {
            failure = failure ?? error.localizedDescription
            for frame in staged.dropFirst(index) {
                appendPending(frame.pts, duration: frame.duration,
                              reason: frame.dropReason ?? "staging_encode_failed")
            }
        }
        staged.removeAll()
    }

    func finish(partialReason: String?) async -> String? {
        await withCheckedContinuation { continuation in
            processing.async { continuation.resume() }
        }
        failure = failure ?? partialReason
        writeEvent(CaptureEvent(kind: "finishing", detail: failure ?? "stop"))
        if let spool { await encodeStagedFrames(spool) }
        do { try encoder.complete() }
        catch { failure = failure ?? error.localizedDescription }
        let deadline = Date().addingTimeInterval(5)
        while !pending.isEmpty {
            drain(finishing: true, deadline: deadline)
            if !pending.isEmpty { try? await Task.sleep(for: .milliseconds(4)) }
        }
        flushCSV()
        do { try csv.close() }
        catch { failure = failure ?? error.localizedDescription }
        if writer.status == .writing, let lastAccepted, let origin, let input {
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
                writeEvent(CaptureEvent(kind: "video_verification",
                                 detail: "writer=\(accepted.count), mov=\(movie.count), pts_match=\(properties.ptsMatch)"))
                if properties.ptsMatch && accepted.count == stagedFrameCount {
                    do { try spool?.discard() }
                    catch { writeEvent(CaptureEvent(kind: "staging_cleanup_failed", detail: error.localizedDescription)) }
                }
                if !properties.ptsMatch {
                    let mismatch = zip(accepted, movie).enumerated().first {
                        CMTimeSubtract($0.element.0.time, origin) != $0.element.1.time
                    }
                    if let mismatch {
                        let (source, saved) = mismatch.element
                        let expected = FrameTime(CMTimeSubtract(source.time, origin))
                        writeEvent(CaptureEvent(kind: "pts_mismatch",
                                         detail: "frame=\(mismatch.offset) expected=\(expected.value)/\(expected.timescale) actual=\(saved.value)/\(saved.timescale)"))
                    }
                    failure = failure ?? "動画とCSVのフレーム時刻が一致しません"
                }
            } catch { failure = failure ?? error.localizedDescription }
        }
        writeEvent(CaptureEvent(kind: failure == nil ? "saved" : "partial", detail: failure ?? "completed"))
        metadata.frameCount = accepted.count
        metadata.status = failure == nil ? "saved" : "partial"
        metadata.error = failure
        do { try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json")) }
        catch { failure = failure ?? error.localizedDescription }
        return failure
    }
}
