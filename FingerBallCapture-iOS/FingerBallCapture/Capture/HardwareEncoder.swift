import VideoToolbox
import Foundation

final class HardwareEncoder {
    struct Result {
        let status: OSStatus
        let sample: CMSampleBuffer?
    }

    private let session: VTCompressionSession
    private let lock = NSLock()
    private var results: [Int: Result] = [:]
    let codec: String

    init(mode: CameraMode) throws {
        let highSpeed = mode.fps >= 120
        codec = highSpeed ? "hevc" : "h264"
        var specification: [String: Any] = [:]
        #if !targetEnvironment(simulator)
        if #available(iOS 17.4, *) {
            specification[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true
        }
        #endif
        var session: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: mode.width,
                                                  height: mode.height,
                                                  codecType: highSpeed ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                                  encoderSpecification: specification as CFDictionary,
                                                  imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &session))
        guard let session else { throw CaptureError.message("動画エンコーダーを初期化できません") }
        self.session = session
        try Self.check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: highSpeed ? kCFBooleanFalse : kCFBooleanTrue))
        try Self.check(VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse))
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: mode.fps)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: mode.width >= 1920 ? 30_000_000 : 12_000_000))
        ]
        for (key, value) in settings { VTSessionSetProperty(session, key: key, value: value) }
        try Self.check(VTCompressionSessionPrepareToEncodeFrames(session))
    }

    deinit { VTCompressionSessionInvalidate(session) }

    func submit(_ image: CVPixelBuffer, at pts: CMTime, index: Int) throws {
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: pts,
                                                      duration: .invalid, frameProperties: nil,
                                                      infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            let result = Result(status: status, sample: flags.contains(.frameDropped) ? nil : sample)
            self.lock.withLock { self.results[index] = result }
        }
        try Self.check(status)
    }

    func takeResult(at index: Int) -> Result? {
        lock.withLock { results.removeValue(forKey: index) }
    }

    func complete() throws {
        try Self.check(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CaptureError.message("動画エンコーダーエラー (\(status))") }
    }
}
