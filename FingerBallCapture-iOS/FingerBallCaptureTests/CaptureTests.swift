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
                                   mode: CameraMode(width: 64, height: 64, fps: 240),
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
            XCTAssertNil(writer.receive(try XCTUnwrap(sample)))
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

    private func dummyTake() -> Take {
        Take(sessionID: UUID(), takeID: UUID(), subjectID: "TEST_001", throwNumber: 3, throwingHand: "R")
    }
}
