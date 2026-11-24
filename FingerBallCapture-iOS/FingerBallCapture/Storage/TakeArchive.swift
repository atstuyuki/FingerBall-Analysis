import Foundation

enum TakeArchive {
    static func create(_ folder: URL) throws -> URL {
        let temporary = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let destination = temporary.appending(path: folder.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordinationError) { zippedURL in
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
