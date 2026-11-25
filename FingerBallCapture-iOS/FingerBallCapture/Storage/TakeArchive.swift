import Foundation

enum TakeArchive {
    static func create(_ folder: URL) throws -> URL {
        let temporary = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = temporary.appending(path: folder.lastPathComponent + ".zip")
        let exportFolder = temporary.appending(path: folder.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: false)
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles]) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let destination = exportFolder.appending(path: file.lastPathComponent)
                do { try FileManager.default.linkItem(at: file, to: destination) }
                catch { try FileManager.default.copyItem(at: file, to: destination) }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        defer { try? FileManager.default.removeItem(at: exportFolder) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: exportFolder, options: .forUploading, error: &coordinationError) { zippedURL in
            do { try FileManager.default.copyItem(at: zippedURL, to: destination) }
            catch { copyError = error }
        }
        if let error = copyError ?? coordinationError {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            try? FileManager.default.removeItem(at: temporary)
            throw CaptureError.message("ZIPを作成できませんでした")
        }
        return destination
    }
}
