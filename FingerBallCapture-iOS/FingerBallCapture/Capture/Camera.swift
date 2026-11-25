import AVFoundation
import UIKit

// Capture state is confined to queue. The preview only reads the session reference.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.fingerball.capture.camera")
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var formats: [(CameraMode, AVCaptureDevice.Format)] = []
    private var recording: Recording?
    private var finishing = false
    private var failureReported = false
    private var observers: [NSObjectProtocol] = []
    var onFailure: ((String) -> Void)?
    var onInterruption: ((String) -> Void)?
    var onInterruptionEnded: (() -> Void)?

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] notice in
                let error = notice.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let reason = (notice.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)
                    .flatMap { AVCaptureSession.InterruptionReason(rawValue: $0.intValue) }
                let message: String
                switch reason {
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    message = "カメラを使うには、FingerBall Captureを全画面で開いてください。"
                case .videoDeviceInUseByAnotherClient:
                    message = "別のアプリがカメラを使用しています。そのアプリを閉じてください。"
                case .videoDeviceNotAvailableInBackground:
                    message = "アプリを前面に戻すと、カメラを再開します。"
                default:
                    message = error?.localizedDescription ?? "カメラが中断されました。再接続を試せます。"
                }
                self?.queue.async { [weak self] in
                    self?.recording?.log(CaptureEvent(kind: "camera_interruption", detail: message))
                    DispatchQueue.main.async { [weak self] in self?.onInterruption?(message) }
                }
            })
        }
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
                                            object: session, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.onInterruptionEnded?() }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func prepare(restart: Bool = false) async throws -> [CameraMode] {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw CaptureError.message("設定でカメラのアクセスを許可してください")
        }
        return try await perform {
            if self.device == nil { try self.installCamera() }
            if restart && self.recording == nil && self.session.isRunning {
                self.session.stopRunning()
            }
            if !self.session.isRunning { self.session.startRunning() }
            guard self.session.isRunning && !self.session.isInterrupted else {
                throw CaptureError.message("カメラに接続できません。アプリを全画面で開き、カメラを再接続してください。")
            }
            return self.formats.map { $0.0 }.reduce(into: [CameraMode]()) { result, mode in
                if !result.contains(mode) { result.append(mode) }
            }
        }
    }

    func suspendPreview() {
        queue.async {
            if self.recording == nil && self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func installCamera() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.message("背面カメラを使用できません")
        }
        let modes = device.formats.flatMap { format -> [(CameraMode, AVCaptureDevice.Format)] in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let rates = format.videoSupportedFrameRateRanges
            let candidates = Set([24, 25, 30, 50, 60, 120, 240] +
                                 rates.map { Int($0.maxFrameRate.rounded(.down)) })
            return candidates.sorted(by: >).compactMap { fps in
                guard fps > 0, rates.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) else { return nil }
                return (CameraMode(width: size.width, height: size.height, fps: fps), format)
            }
        }.sorted { ($0.0.fps, $0.0.width, $0.0.height) > ($1.0.fps, $1.0.width, $1.0.height) }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input) else { throw CaptureError.message("カメラ入力を追加できません") }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw CaptureError.message("カメラ出力を追加できません")
        }
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
        self.device = device
        formats = modes
    }

    func start(take: Take, role: DeviceRole, view: Viewpoint, mode: CameraMode,
               lockExposure: Bool, lockFocus: Bool, rotation: Int, iosVersion: String,
               events: [CaptureEvent]) async throws {
        try await perform {
            guard self.recording == nil, !self.finishing, self.session.isRunning, !self.session.isInterrupted,
                  let device = self.device, let format = self.formats.first(where: { $0.0 == mode })?.1 else {
                throw CaptureError.message("カメラが録画可能な状態ではありません")
            }
            self.session.beginConfiguration()
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: Int32(mode.fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                if device.isExposureModeSupported(.continuousAutoExposure) || device.isExposureModeSupported(.locked) {
                    let requested: AVCaptureDevice.ExposureMode = lockExposure ? .locked : .continuousAutoExposure
                    if device.isExposureModeSupported(requested) { device.exposureMode = requested }
                }
                let focus: AVCaptureDevice.FocusMode = lockFocus ? .locked : .continuousAutoFocus
                if device.isFocusModeSupported(focus) { device.focusMode = focus }
                if let connection = self.output.connection(with: .video), connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            } catch {
                self.session.commitConfiguration()
                throw error
            }
            self.session.commitConfiguration()
            guard device.activeVideoMinFrameDuration == CMTime(value: 1, timescale: Int32(mode.fps)),
                  device.activeVideoMaxFrameDuration == CMTime(value: 1, timescale: Int32(mode.fps)) else {
                throw CaptureError.message("選択したFPSをカメラに設定できません")
            }
            let settings = CameraSettings(camera: device.localizedName, fieldOfViewDegrees: format.videoFieldOfView,
                                          zoom: device.videoZoomFactor, exposureDuration: FrameTime(device.exposureDuration),
                                          iso: device.iso, exposureMode: device.exposureMode == .locked ? "locked" : "auto",
                                          focusMode: device.focusMode == .locked ? "locked" : "auto",
                                          lensPosition: device.lensPosition,
                                          stabilization: self.output.connection(with: .video)?.activeVideoStabilizationMode == .off ? "off" : "unavailable",
                                          rotationDegrees: rotation)
            let recording = try Recording(take: take, role: role, view: view, mode: mode,
                                          camera: settings, iosVersion: iosVersion)
            events.forEach(recording.log)
            self.failureReported = false
            self.recording = recording
        }
    }

    func log(_ event: CaptureEvent) {
        queue.async { self.recording?.log(event) }
    }

    func stop(partialReason: String? = nil) async throws -> (URL, String?) {
        let current: Recording = try await perform {
            guard let recording = self.recording else { throw CaptureError.message("録画がありません") }
            self.recording = nil
            self.finishing = true
            return recording
        }
        let failure = await current.finish(partialReason: partialReason)
        await clearFinishing()
        return (current.folder, failure)
    }

    private func clearFinishing() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finishing = false
                continuation.resume()
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let failure = recording?.receive(sampleBuffer) { reportFailure(failure) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        recording?.dropped(sampleBuffer)
    }

    private func reportFailure(_ message: String) {
        if recording != nil {
            guard !failureReported else { return }
            failureReported = true
            recording?.log(CaptureEvent(kind: "capture_failure", detail: message))
        }
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}
