import AVFoundation
import CoreGraphics

// The capture queue copies source surfaces. The processing queue encodes and writes them.
// Finish takes ownership after Capture detaches the writer and the processing queue drains.
final class Recording {
    static let header = "record_index,source_pts_value,source_pts_timescale,source_pts_seconds,writer_pts_seconds,accepted_by_writer,reason,writer_pts_value,writer_pts_timescale\n"
    let folder: URL
    private let writer: AVAssetWriter
    private var input: AVAssetWriterInput?
    private let encoder: HardwareEncoder
    private let spool: FrameSpool?
    private var staged: [PendingFrame] = []
    private var lastStaged: CMTime?
    private var stagedFrameCount = 0
    private var journal: FileHandle?
    private var spoolLayout: FrameSpool.Layout?
    private var lastObservedPTS: CMTime?
    private let recovering: Bool

    private let rotation: CGAffineTransform
    private struct PendingFrame: Codable {
        let pts: CMTime
        let duration: CMTime
        let dropReason: String?

        private enum CodingKeys: String, CodingKey { case pts, duration, dropReason }
        init(pts: CMTime, duration: CMTime, dropReason: String?) {
            self.pts = pts
            self.duration = duration
            self.dropReason = dropReason
        }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            pts = try box.decodeIfPresent(FrameTime.self, forKey: .pts)?.time ?? .invalid
            duration = try box.decodeIfPresent(FrameTime.self, forKey: .duration)?.time ?? .invalid
            dropReason = try box.decodeIfPresent(String.self, forKey: .dropReason)
        }
        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            if pts.isNumeric { try box.encode(FrameTime(pts), forKey: .pts) }
            if duration.isNumeric { try box.encode(FrameTime(duration), forKey: .duration) }
            try box.encodeIfPresent(dropReason, forKey: .dropReason)
        }
    }
    private var pending: [Int: PendingFrame] = [:]
    private var nextToWrite = 0
    private var lastSubmitted: CMTime?
    private var encoded: HardwareEncoder.Result?
    private let processing = DispatchQueue(label: "org.fingerball.capture.encode", qos: .userInitiated)
    private let slots: DispatchSemaphore
    private let maximumQueuedFrames: Int
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
        if mode.fps >= 120,
           let available = try? store.root.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           available < 128 * 1024 * 1024 + Int(mode.width) * Int(mode.height) * 3 / 2 * mode.fps {
            throw CaptureError.message("高速録画を開始するための空き容量が不足しています")
        }
        let device = SessionStore.deviceID
        let folder = try store.createTake(take, device: device, view: view)
        self.folder = folder
        recovering = false
        metadata = Metadata(sessionID: take.sessionID, takeID: take.takeID, deviceID: device, deviceRole: role,
                            viewType: view, subjectID: take.subjectID, throwNumber: take.throwNumber,
                            throwingHand: take.throwingHand, deviceModel: SessionStore.deviceModel,
                            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                            iosVersion: iosVersion, selectedFormat: mode, cameraSettings: camera,
                            frameCount: 0, dropCount: 0, status: "preparing")
        writer = try AVAssetWriter(outputURL: folder.appending(path: "original.mov"), fileType: .mov)
        encoder = try HardwareEncoder(mode: mode)
        spool = mode.fps >= 120 ? try FrameSpool(folder: folder) : nil
        // About 270 ms of 240 fps input covers short stalls in the storage path.
        maximumQueuedFrames = mode.fps >= 120 ? 64 : 32
        slots = DispatchSemaphore(value: maximumQueuedFrames)
        rotation = CGAffineTransform(rotationAngle: CGFloat(camera.rotationDegrees) * .pi / 180)
        let csvURL = folder.appending(path: "frame_timestamps.csv")
        try Data(Self.header.utf8).write(to: csvURL)
        csv = try FileHandle(forWritingTo: csvURL)
        try csv.seekToEnd()
        try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))
        if spool != nil {
            let url = folder.appending(path: ".capture-journal")
            try Data().write(to: url)
            journal = try FileHandle(forWritingTo: url)
        }
        log(CaptureEvent(kind: "armed", detail: mode.label + ", codec=" + encoder.codec))
    }

    func log(_ event: CaptureEvent) {
        processing.async {
            var event = event
            if event.sourcePTS == nil, let pts = self.lastObservedPTS { event.sourcePTS = FrameTime(pts) }
            self.writeEvent(event)
        }
    }

    private func writeEvent(_ event: CaptureEvent) {
        do { try SessionStore.log(event, to: folder) }
        catch { recordFailure(error.localizedDescription) }
    }

    func receive(_ sample: CMSampleBuffer) {
        let pts = sample.presentationTimeStamp
        let duration = sample.duration
        guard pts.isNumeric else {
            enqueueDrop(pts, reason: "invalid_pts")
            return
        }
        guard slots.wait(timeout: .now()) == .success else {
            enqueueDrop(pts, reason: spool == nil ? "encoder_input_queue_full" : "staging_input_queue_full")
            return
        }
        do {
            guard let image = sample.imageBuffer else {
                throw CaptureError.message("カメラサンプルに映像がありません")
            }
            if encoderBuffers == nil { encoderBuffers = try EncoderBuffers(source: image, maximumBuffers: maximumQueuedFrames) }
            guard let owned = try encoderBuffers?.copy(image) else {
                slots.signal()
                enqueueDrop(pts, reason: "encoder_pool_full")
                return
            }
            processing.async {
                defer { self.slots.signal() }
                self.observe(pts)
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
                if spoolLayout == nil {
                    let layout = FrameSpool.Layout(image)
                    try SessionStore.writeJSON(layout, to: folder.appending(path: ".capture-layout"))
                    spoolLayout = layout
                }
                if stagedFrameCount % max(1, metadata.selectedFormat.fps / 2) == 0,
                   let available = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
                   available < max(128 * 1024 * 1024, (spoolLayout?.planeBytes.reduce(0, +) ?? 0) * 4) {
                    throw CaptureError.message("空き容量が不足したため高速録画を停止しました")
                }
                try spool.append(image)
                stagedFrameCount += 1
                lastStaged = pts
            } catch {
                reason = "staging_write_failed"
                recordFailure(error.localizedDescription)
            }
        }
        persistStaged(PendingFrame(pts: pts, duration: duration, dropReason: reason))
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
        observe(pts)
        if spool != nil {
            persistStaged(PendingFrame(pts: pts, duration: .invalid, dropReason: reason))
        } else {
            drain()
            appendPending(pts, duration: .invalid, reason: reason)
            if pending.count >= 1_024 { recordFailure("MOVの書き込みが映像入力に追いつきません") }
        }
    }

    private func observe(_ pts: CMTime) {
        guard pts.isNumeric else { return }
        if let previous = lastObservedPTS {
            guard pts > previous else { return }
            let intervals = CMTimeSubtract(pts, previous).seconds * Double(metadata.selectedFormat.fps)
            if intervals > 1.5 && intervals < Double(Int32.max) {
                let missing = Int(intervals.rounded()) - 1
                metadata.inferredMissingCount = (metadata.inferredMissingCount ?? 0) + missing
                writeEvent(CaptureEvent(kind: "source_pts_gap", detail: "estimated_missing=\(missing), intervals=\(intervals)",
                                        sourcePTS: FrameTime(pts)))
            }
        }
        lastObservedPTS = pts
    }

    private func persistStaged(_ frame: PendingFrame) {
        staged.append(frame)
        guard let journal else { return }
        do {
            var line = try JSONEncoder().encode(frame)
            line.append(10)
            try journal.write(contentsOf: line)
        } catch { recordFailure(error.localizedDescription) }
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
                writeRow(frame.pts, written: false, reason: result.status == noErr ? "encoder_frame_dropped" : "encoder_error_\(result.status)")
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
        let relative = written ? origin.map { CMTimeSubtract(pts, $0) } : nil
        let line = "\(nextToWrite),\(pts.value),\(pts.timescale),\(source),\(relative.map { String($0.seconds) } ?? ""),\(written),\(reason),\(relative.map { String($0.value) } ?? ""),\(relative.map { String($0.timescale) } ?? "")\n"
        pending.removeValue(forKey: nextToWrite)
        nextToWrite += 1
        if !written { metadata.dropCount += 1 }
        csvBuffer.append(contentsOf: line.utf8)
        if csvBuffer.count >= 4_096 { flushCSV() }
    }

    private func flushCSV() {
        do { try csv.write(contentsOf: csvBuffer) }
        catch { recordFailure(error.localizedDescription) }
        csvBuffer.removeAll(keepingCapacity: true)
    }

    private func encodeStagedFrames(_ spool: FrameSpool, shouldDefer: () -> Bool) async {
        do {
            try spool.rewind()
            for frame in staged {
                if shouldDefer() { return }
                if let reason = frame.dropReason {
                    appendPending(frame.pts, duration: frame.duration, reason: reason)
                    drain()
                    continue
                }
                let deadline = Date().addingTimeInterval(5)
                var image = try encoderBuffers?.allocate()
                while (image == nil || pending.count >= 48) && Date() < deadline {
                    if shouldDefer() { return }
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

    func finish(partialReason: String?, shouldDefer: @escaping () -> Bool = { false }) async -> String? {
        await withCheckedContinuation { continuation in
            processing.async { continuation.resume() }
        }
        failure = failure ?? partialReason
        try? journal?.close()
        journal = nil
        if recovering {
            metadata.inferredMissingCount = 0
            for frame in staged { observe(frame.pts) }
        }
        if spool != nil && shouldDefer() {
            return deferConversion()
        }
        writeEvent(CaptureEvent(kind: "finishing", detail: failure ?? "stop"))
        if let spool {
            await encodeStagedFrames(spool, shouldDefer: shouldDefer)
            if shouldDefer() {
                if writer.status == .writing { writer.cancelWriting() }
                return deferConversion()
            }
        }
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
                metadata.frameCount = properties.frameCount
                let frameIndex = try SavedFrameIndex.read(folder: folder, movie: movie, origin: FrameTime(origin))
                properties.ptsMatch = frameIndex.unmatchedMovie == 0 && frameIndex.unmatchedWriter == 0
                    && VideoFrames.matches(source: accepted, movie: movie, origin: origin)
                metadata.actualVideoProperties = properties
                try frameIndex.writeMovieIndex(to: folder)
                writeEvent(CaptureEvent(kind: "video_verification",
                                 detail: "writer=\(accepted.count), mov=\(movie.count), pts_match=\(properties.ptsMatch)"))
                if !properties.ptsMatch {
                    writeEvent(CaptureEvent(kind: "pts_mismatch_summary",
                                            detail: "unmatched_writer=\(frameIndex.unmatchedWriter), unmatched_movie=\(frameIndex.unmatchedMovie)"))
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
        metadata.writerAcceptedCount = accepted.count
        metadata.movieOrigin = origin.map(FrameTime.init)
        metadata.inferredMissingCount = metadata.inferredMissingCount ?? 0
        metadata.schemaVersion = 2
        metadata.status = failure == nil ? "saved" : "partial"
        metadata.error = failure
        do {
            try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))
            if !recovering, metadata.actualVideoProperties?.ptsMatch == true, accepted.count == stagedFrameCount, spool != nil {
                Self.removeScratch(in: folder)
            }
        } catch { failure = failure ?? error.localizedDescription }
        return failure
    }

    private func deferConversion() -> String {
        let message = "録画を一時保存しました。テイクを開いてMOVを復元してください。"
        metadata.status = "partial"
        metadata.error = message
        try? csv.close()
        writeEvent(CaptureEvent(kind: "conversion_deferred", detail: message))
        try? SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))
        return message
    }

    private static func removeScratch(in folder: URL) {
        for name in [".capture-frames", ".capture-journal", ".capture-layout"] {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }

    static func canRecover(_ folder: URL) -> Bool {
        [".capture-frames", ".capture-journal", ".capture-layout"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    private init(recovering source: URL, destination: URL) throws {
        folder = destination
        recovering = true
        metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: source.appending(path: "metadata.json")))
        metadata.frameCount = 0
        metadata.dropCount = 0
        metadata.actualVideoProperties = nil
        let layout = try JSONDecoder().decode(FrameSpool.Layout.self,
                                              from: Data(contentsOf: source.appending(path: ".capture-layout")))
        let raw = source.appending(path: ".capture-frames")
        let size = try raw.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let bytesPerFrame = layout.planeBytes.reduce(0, +)
        guard bytesPerFrame > 0 else { throw CaptureError.message("復元できる画素情報がありません") }
        var available = size / bytesPerFrame
        let data = try Data(contentsOf: source.appending(path: ".capture-journal"))
        let records = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        for record in records {
            let frame = try JSONDecoder().decode(PendingFrame.self, from: Data(record))
            if frame.dropReason == nil {
                guard available > 0 else { break }
                available -= 1
                stagedFrameCount += 1
            }
            staged.append(frame)
        }
        guard stagedFrameCount > 0 else { throw CaptureError.message("復元できる完全なフレームがありません") }
        spool = try FrameSpool(folder: source, reading: true, layout: layout)
        encoderBuffers = try EncoderBuffers(source: layout.makeBuffer())
        writer = try AVAssetWriter(outputURL: destination.appending(path: "original.mov"), fileType: .mov)
        encoder = try HardwareEncoder(mode: metadata.selectedFormat)
        rotation = CGAffineTransform(rotationAngle: CGFloat(metadata.cameraSettings.rotationDegrees) * .pi / 180)
        maximumQueuedFrames = 32
        slots = DispatchSemaphore(value: 32)
        let csvURL = destination.appending(path: "frame_timestamps.csv")
        try Data(Self.header.utf8).write(to: csvURL)
        csv = try FileHandle(forWritingTo: csvURL)
        try csv.seekToEnd()
    }

    static func recover(_ folder: URL, shouldDefer: @escaping () -> Bool) async throws {
        let work = folder.appending(path: ".recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: work) }
        let recording = try Recording(recovering: folder, destination: work)
        let failure = await recording.finish(partialReason: "中断後に保存済みのフレームを復元しました", shouldDefer: shouldDefer)
        guard !shouldDefer(), recording.metadata.actualVideoProperties?.ptsMatch == true,
              recording.metadata.frameCount == recording.stagedFrameCount else {
            throw CaptureError.message(failure ?? "復元結果を検証できません")
        }
        for name in ["original.mov", "frame_timestamps.csv", "verified_movie_frames.csv", "metadata.json"] {
            let target = folder.appending(path: name)
            let staged = work.appending(path: name)
            if rename(staged.path, target.path) != 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        try? SessionStore.log(CaptureEvent(kind: "recovered", detail: "\(recording.metadata.frameCount) frames"), to: folder)
        removeScratch(in: folder)
    }
}
