import Foundation
import Darwin

@main
struct VerifyTake {
    static func main() async {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CaptureError.message("Usage: scripts/verify-take <exported-take-folder>")
            }
            let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let metadata = try JSONDecoder().decode(Metadata.self,
                                                     from: Data(contentsOf: folder.appending(path: "metadata.json")))
            guard let origin = metadata.movieOrigin else {
                throw CaptureError.message("This take has no stored MOV time origin.")
            }
            let (properties, movie) = try await VideoFrames.inspect(folder.appending(path: "original.mov"))
            let index = try SavedFrameIndex.read(folder: folder, movie: movie, origin: origin)
            print("MOV frames: \(properties.frameCount); verified: \(index.byMovieFrame.count); unmatched writer: \(index.unmatchedWriter); unmatched MOV: \(index.unmatchedMovie)")
            guard index.unmatchedWriter == 0, index.unmatchedMovie == 0,
                  metadata.frameCount == properties.frameCount else {
                exit(1)
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
