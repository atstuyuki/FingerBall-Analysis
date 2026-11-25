import Foundation
import CoreMedia

struct SavedFrameIndex {
    struct Entry {
        let recordIndex: Int
        let source: FrameTime
        let movie: FrameTime
    }

    let byMovieFrame: [Int: Entry]
    let unmatchedWriter: Int
    let unmatchedMovie: Int

    static func read(folder: URL, movie: [FrameTime], origin: FrameTime) throws -> SavedFrameIndex {
        let contents = try String(contentsOf: folder.appending(path: "frame_timestamps.csv"), encoding: .utf8)
        var entries: [Entry] = []
        for line in contents.split(whereSeparator: \.isNewline).dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 7 else { throw CaptureError.message("CSVのフレーム行を読み込めません") }
            guard fields[5] == "true" else { continue }
            guard fields.count >= 9, let index = Int(fields[0]), let value = Int64(fields[1]),
                  let scale = Int32(fields[2]), scale > 0, let movieValue = Int64(fields[7]),
                  let movieScale = Int32(fields[8]), movieScale > 0 else {
                throw CaptureError.message("CSVに照合用の整数時刻がありません")
            }
            let source = FrameTime(CMTime(value: value, timescale: scale))
            let saved = FrameTime(CMTime(value: movieValue, timescale: movieScale))
            guard CMTimeSubtract(source.time, origin.time) == saved.time else {
                throw CaptureError.message("CSVの元時刻とMOV基準点が一致しません")
            }
            entries.append(Entry(recordIndex: index, source: source, movie: saved))
        }
        var mapping: [Int: Entry] = [:]
        var index = 0
        for (movieIndex, time) in movie.enumerated() {
            while index < entries.count && entries[index].movie.time < time.time { index += 1 }
            if index < entries.count && entries[index].movie.time == time.time {
                mapping[movieIndex] = entries[index]
                index += 1
            }
        }
        return SavedFrameIndex(byMovieFrame: mapping, unmatchedWriter: entries.count - mapping.count,
                               unmatchedMovie: movie.count - mapping.count)
    }

    func writeMovieIndex(to folder: URL) throws {
        var csv = "movie_frame_index,record_index,source_pts_value,source_pts_timescale,movie_pts_value,movie_pts_timescale\n"
        for (index, entry) in byMovieFrame.sorted(by: { $0.key < $1.key }) {
            csv += "\(index),\(entry.recordIndex),\(entry.source.value),\(entry.source.timescale),\(entry.movie.value),\(entry.movie.timescale)\n"
        }
        try Data(csv.utf8).write(to: folder.appending(path: "verified_movie_frames.csv"), options: .atomic)
    }
}

final class ConversionPause: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    func request() { lock.withLock { requested = true } }
    var isRequested: Bool { lock.withLock { requested } }
}
