import Foundation
import CoreMedia

enum DeviceRole: String, CaseIterable, Codable {
    case solo = "単体", controller = "親機", recorder = "子機"
}

enum Viewpoint: String, CaseIterable, Codable {
    case rear = "後方全体", oblique = "後方斜め", hand = "手部拡大"
}

struct Take: Codable, Equatable {
    var sessionID: UUID
    var takeID: UUID
    var subjectID: String
    var throwNumber: Int
    var throwingHand: String

    var isValid: Bool {
        subjectID.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil
            && (1...99999).contains(throwNumber) && ["R", "L"].contains(throwingHand)
    }
}

struct FrameTime: Codable, Equatable {
    var value: Int64
    var timescale: Int32

    init(_ time: CMTime) {
        value = time.value
        timescale = time.timescale
    }

    var time: CMTime { CMTime(value: value, timescale: timescale) }
}

struct CameraMode: Codable, Hashable {
    var width: Int32
    var height: Int32
    var fps: Int

    var label: String { "\(width)×\(height) / \(fps) fps" }

    static let target = CameraMode(width: 1920, height: 1080, fps: 240)

    static func automaticChoice(_ modes: [CameraMode]) -> CameraMode? {
        modes.first { $0 == target }
    }
}

struct CameraSettings: Codable {
    var camera: String
    var fieldOfViewDegrees: Float
    var zoom: Double
    var exposureDuration: FrameTime
    var iso: Float
    var exposureMode: String
    var focusMode: String
    var lensPosition: Float
    var stabilization: String
    var rotationDegrees: Int
}

struct VideoProperties: Codable {
    var width: Int
    var height: Int
    var nominalFPS: Float
    var frameCount: Int
    var ptsMatch: Bool
}

struct Metadata: Codable {
    var schemaVersion = 1
    var targetFPS = 240
    var captureClockInfo = "Camera sample PTS on the local capture clock. MOV timestamps are relative to the first source sample. Device clocks are independent."
    var sessionID: UUID
    var takeID: UUID
    var deviceID: UUID
    var deviceRole: DeviceRole
    var viewType: Viewpoint
    var subjectID: String
    var throwNumber: Int
    var throwingHand: String
    var deviceModel: String
    var appVersion: String
    var iosVersion: String
    var selectedFormat: CameraMode
    var cameraSettings: CameraSettings
    var frameCount: Int
    var dropCount: Int
    var actualVideoProperties: VideoProperties?
    var status: String
    var error: String?
}

struct CaptureEvent: Codable {
    var kind: String
    var detail: String
    var wallTime = Date()
    var uptime = ProcessInfo.processInfo.systemUptime
}

extension Metadata {
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", targetFPS = "target_fps", captureClockInfo = "capture_clock_info"
        case sessionID = "session_id", takeID = "take_id", deviceID = "device_id", deviceRole = "device_role"
        case viewType = "view_type", subjectID = "subject_id", throwNumber = "throw_number"
        case throwingHand = "throwing_hand", deviceModel = "device_model", appVersion = "app_version"
        case iosVersion = "ios_version", selectedFormat = "selected_format", cameraSettings = "camera_settings"
        case frameCount = "frame_count", dropCount = "drop_count", actualVideoProperties = "actual_video_properties"
        case status, error
    }
}
