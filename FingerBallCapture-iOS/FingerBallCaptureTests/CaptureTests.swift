import AVFoundation
import XCTest
@testable import FingerBallCapture

final class CaptureTests: XCTestCase {
    func testOnlyExactTargetIsAutomaticallySelected() {
        let fallback = CameraMode(width: 1920, height: 1080, fps: 120)
        let small = CameraMode(width: 1280, height: 720, fps: 240)
        XCTAssertNil(CameraMode.automaticChoice([fallback, small]))
        XCTAssertEqual(CameraMode.automaticChoice([fallback, .target, small]), .target)
    }

    func testResearchAndCommandRoundTrip() throws {
        let take = dummyTake()
        XCTAssertTrue(take.isValid)
        let command = Command(action: .arm, take: take)
        let decoded = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command))
        XCTAssertEqual(decoded, command)
        var invalid = take
        invalid.subjectID = "個人名"
        XCTAssertFalse(invalid.isValid)
        invalid = take
        invalid.throwNumber = 0
        XCTAssertFalse(invalid.isValid)
    }

    func testDuplicateCommandCannotStartAnotherRecording() {
        let command = Command(action: .start, take: dummyTake())
        var history = CommandHistory()
        XCTAssertTrue(history.accept(command.id))
        XCTAssertFalse(history.accept(command.id))
        let reply = Reply(commandID: command.id, takeID: command.take.takeID, status: "recording")
        history.save(reply)
        XCTAssertFalse(history.accept(command.id))
        XCTAssertEqual(history.reply(for: command.id)?.status, "recording")
    }

    func testOnlyQuiescentStatesAllowNewTake() {
        for state: CaptureState in [.idle, .saved, .partial] { XCTAssertTrue(state.permitsNewTake) }
        for state: CaptureState in [.armed, .starting, .recording, .finishing] { XCTAssertFalse(state.permitsNewTake) }
    }

    func testTimestampComparisonPreservesGapAndOrdering() {
        let source = [2400, 2401, 2404].map { FrameTime(CMTime(value: $0, timescale: 240)) }
        let movie = [0, 2, 8].map { FrameTime(CMTime(value: $0, timescale: 480)) }
        XCTAssertTrue(VideoFrames.matches(source: source, movie: movie, origin: source[0].time))
        XCTAssertFalse(VideoFrames.matches(source: source, movie: Array(movie.reversed()), origin: source[0].time))
        XCTAssertFalse(VideoFrames.matches(source: source, movie: Array(movie.prefix(2)), origin: source[0].time))
    }

    func testManualAnnotationRoundTrip() throws {
        let unobserved = EventAnnotation(event: .strideFootContact, observation: "not_observed")
        let observed = EventAnnotation(event: .ballRelease, frameIndex: 2,
                                       moviePTS: FrameTime(CMTime(value: 2, timescale: 240)), observation: "observed")
        let data = try SessionStore.encoder().encode(Annotations(labels: [observed, unobserved]))
        XCTAssertEqual(try JSONDecoder().decode(Annotations.self, from: data).labels, [observed, unobserved])
    }

    func testSyntheticWriterPreservesSourceTimingAndExports() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let duration = CMTime(value: 1, timescale: 240)
        let frameTime = FrameTime(duration)
        let settings = CameraSettings(camera: "fixture", fieldOfViewDegrees: 60, zoom: 1,
                                      exposureDuration: frameTime, iso: 100, exposureMode: "locked",
                                      focusMode: "locked", lensPosition: 0, stabilization: "off", rotationDegrees: 0)
        let writer = try Recording(take: dummyTake(), role: .solo, view: .rear,
                                   mode: CameraMode(width: 64, height: 64, fps: 30),
                                   camera: settings, iosVersion: "fixture", store: store)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        if let base = CVPixelBufferGetBaseAddress(pixels) {
            memset(base, 40, CVPixelBufferGetDataSize(pixels))
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                    imageBuffer: pixels, formatDescriptionOut: &description), noErr)
        for tick: Int64 in [2400, 2401, 2403, 2404] {
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: duration,
                                            presentationTimeStamp: CMTime(value: tick, timescale: 240),
                                            decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                                     formatDescription: try XCTUnwrap(description),
                                                                     sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            writer.receive(try XCTUnwrap(sample))
            try await Task.sleep(for: .milliseconds(30))
        }
        let failure = await writer.finish(partialReason: nil)
        XCTAssertNil(failure, (try? String(contentsOf: writer.folder.appending(path: "capture_events.jsonl"), encoding: .utf8)) ?? "")
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: writer.folder.appending(path: "metadata.json")))
        XCTAssertEqual(metadata.frameCount, 4)
        XCTAssertEqual(metadata.dropCount, 0)
        XCTAssertEqual(metadata.actualVideoProperties?.ptsMatch, true)
        XCTAssertEqual(metadata.actualVideoProperties?.frameCount, 4)
        XCTAssertEqual(store.takes().map(\.path), [writer.folder.path])
        let csv = try String(contentsOf: writer.folder.appending(path: "frame_timestamps.csv"), encoding: .utf8)
        XCTAssertTrue(csv.contains("2,2403,240,"))
        let archive = try TakeArchive.create(writer.folder)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: archive).prefix(2), Data([0x50, 0x4b]))
    }

    func testFrameSpoolRoundTripsTwoFramesInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let spool = try FrameSpool(folder: folder)

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        let pool = try EncoderBuffers(source: pixels)
        let source = try XCTUnwrap(pool.allocate())
        let restored = try XCTUnwrap(pool.allocate())
        for level: Int32 in [33, 169] {
            CVPixelBufferLockBaseAddress(source, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                let size = CVPixelBufferGetHeightOfPlane(source, plane) * CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                memset(CVPixelBufferGetBaseAddressOfPlane(source, plane), level, size)
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            try spool.append(source)
        }
        try spool.rewind()
        for level: UInt8 in [33, 169] {
            try spool.read(into: restored)
            CVPixelBufferLockBaseAddress(restored, .readOnly)
            for plane in 0..<CVPixelBufferGetPlaneCount(restored) {
                let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(restored, plane))
                let size = CVPixelBufferGetHeightOfPlane(restored, plane) * CVPixelBufferGetBytesPerRowOfPlane(restored, plane)
                XCTAssertEqual(Data(bytes: base, count: size), Data(repeating: level, count: size))
            }
            CVPixelBufferUnlockBaseAddress(restored, .readOnly)
        }
        try spool.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.url.path))
    }

    func testInterruptedSpoolCanRecoverCompleteJournaledFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionStore(root: root)
        let take = dummyTake()
        let folder = try store.createTake(take, device: UUID(), view: .rear)
        let timebase: Int32 = 30
        let duration = FrameTime(CMTime(value: 1, timescale: timebase))
        let camera = CameraSettings(camera: "fixture", fieldOfViewDegrees: 60, zoom: 1,
                                    exposureDuration: duration, iso: 100, exposureMode: "locked",
                                    focusMode: "locked", lensPosition: 0, stabilization: "off", rotationDegrees: 0)
        let metadata = Metadata(sessionID: take.sessionID, takeID: take.takeID, deviceID: UUID(), deviceRole: .solo,
                                viewType: .rear, subjectID: take.subjectID, throwNumber: 3, throwingHand: "R",
                                deviceModel: "fixture", appVersion: "fixture", iosVersion: "fixture",
                                selectedFormat: CameraMode(width: 64, height: 64, fps: 30),
                                cameraSettings: camera, frameCount: 0, dropCount: 0, status: "preparing")
        try SessionStore.writeJSON(metadata, to: folder.appending(path: "metadata.json"))

        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &buffer), kCVReturnSuccess)
        let pool = try EncoderBuffers(source: XCTUnwrap(buffer))
        let pixels = try XCTUnwrap(pool.allocate())
        try SessionStore.writeJSON(FrameSpool.Layout(pixels), to: folder.appending(path: ".capture-layout"))
        do {
            let spool = try FrameSpool(folder: folder)
            for _ in 0..<3 { try spool.append(pixels) }
        }
        var journal = ""
        for value in 20...22 {
            journal += "{\"pts\":{\"value\":\(value),\"timescale\":30},\"duration\":{\"value\":1,\"timescale\":30}}\n"
        }
        journal += "{\"pts\":"
        try Data(journal.utf8).write(to: folder.appending(path: ".capture-journal"))
        store.markInterruptedTakes()
        let interrupted = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: folder.appending(path: "metadata.json")))
        XCTAssertEqual(interrupted.status, "partial")
        XCTAssertTrue(Recording.canRecover(folder))

        try await Recording.recover(folder, shouldDefer: { false })
        let (_, frames) = try await VideoFrames.inspect(folder.appending(path: "original.mov"))
        XCTAssertEqual(frames.count, 3)
        let saved = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: folder.appending(path: "metadata.json")))
        XCTAssertEqual(saved.actualVideoProperties?.ptsMatch, true)
        let index = try SavedFrameIndex.read(folder: folder, movie: frames, origin: XCTUnwrap(saved.movieOrigin))
        XCTAssertEqual(index.byMovieFrame[1]?.source.value, 21)
        XCTAssertFalse(Recording.canRecover(folder))
    }

    private func dummyTake() -> Take {
        Take(sessionID: UUID(), takeID: UUID(), subjectID: "TEST_001", throwNumber: 3, throwingHand: "R")
    }
}
