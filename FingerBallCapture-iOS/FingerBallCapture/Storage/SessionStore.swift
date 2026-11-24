import Foundation
import Darwin

struct SessionStore {
    let root: URL

    static var local: SessionStore {
        SessionStore(root: URL.documentsDirectory.appending(path: "FingerBallExports"))
    }

    static let deviceID: UUID = {
        if let stored = UserDefaults.standard.string(forKey: "deviceID"), let id = UUID(uuidString: stored) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "deviceID")
        return id
    }()

    static var deviceModel: String {
        var count = 0
        sysctlbyname("hw.machine", nil, &count, nil, 0)
        guard count > 0 else { return "unavailable" }
        var buffer = [CChar](repeating: 0, count: count)
        guard sysctlbyname("hw.machine", &buffer, &count, nil, 0) == 0 else { return "unavailable" }
        return String(cString: buffer)
    }

    func createTake(_ take: Take, device: UUID, view: Viewpoint) throws -> URL {
        let session = root.appending(path: "session_\(take.sessionID)")
        let deviceFolder = session.appending(path: "device_\(device)")
        try FileManager.default.createDirectory(at: deviceFolder, withIntermediateDirectories: true)
        try Self.writeJSON(Manifest(sessionID: take.sessionID, subjectID: take.subjectID),
                           to: session.appending(path: "session_manifest.json"))
        let folder = deviceFolder.appending(path: String(format: "take_%04d_", take.throwNumber) + take.takeID.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    func takes() -> [URL] {
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return []
        }
        return items.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "metadata.json" }
            .sorted {
                ($0.resourceValuesOrNilDate ?? .distantPast) > ($1.resourceValuesOrNilDate ?? .distantPast)
            }
            .map { $0.deletingLastPathComponent() }
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder().encode(value).write(to: url, options: .atomic)
    }

    static func log(_ event: CaptureEvent, to folder: URL) throws {
        let url = folder.appending(path: "capture_events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var line = try encoder().encode(event)
        line.append(10)
        try handle.write(contentsOf: line)
    }

    private struct Manifest: Encodable {
        var sessionID: UUID
        var subjectID: String
        let schemaVersion = 1

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", subjectID = "subject_id", schemaVersion = "schema_version"
        }
    }
}

private extension URL {
    var resourceValuesOrNilDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
