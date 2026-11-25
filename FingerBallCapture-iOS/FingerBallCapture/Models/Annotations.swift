import Foundation

enum PitchEvent: String, CaseIterable, Codable {
    case ballRelease = "BR"
    case strideFootContact = "SFC"

    var label: String {
        switch self {
        case .ballRelease: return "BR ボール離脱"
        case .strideFootContact: return "SFC 前足接地"
        }
    }
}

struct EventAnnotation: Codable, Equatable {
    var event: PitchEvent
    var frameIndex: Int?
    var moviePTS: FrameTime?
    var observation: String
    var sourceRecordIndex: Int?
    var sourcePTS: FrameTime?
    var provenance = "manual"
}

struct Annotations: Codable {
    var schemaVersion = 1
    var labels: [EventAnnotation] = []
}
