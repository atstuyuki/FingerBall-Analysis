import CoreVideo
import Foundation
import Darwin

// Sequential scratch storage for frames whose capture rate exceeds the live encoder.
final class FrameSpool {
    let url: URL
    private let descriptor: Int32
    private var attachments: CFDictionary?

    struct Layout: Codable {
        let width: Int
        let height: Int
        let pixelFormat: OSType
        let planeBytes: [Int]
        let attachments: Data?

        init(_ image: CVPixelBuffer) {
            width = CVPixelBufferGetWidth(image)
            height = CVPixelBufferGetHeight(image)
            pixelFormat = CVPixelBufferGetPixelFormatType(image)
            planeBytes = FrameSpool.planeBytes(image)
            if let values = CVBufferCopyAttachments(image, .shouldPropagate) {
                attachments = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            } else { attachments = nil }
        }

        func makeBuffer() throws -> CVPixelBuffer {
            var image: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
            guard CVPixelBufferCreate(nil, width, height, pixelFormat, attributes, &image) == kCVReturnSuccess,
                  let image, FrameSpool.planeBytes(image) == planeBytes else {
                throw CaptureError.message("保存された画素配置を復元できません")
            }
            return image
        }
    }

    static func planeBytes(_ image: CVPixelBuffer) -> [Int] {
        let planes = CVPixelBufferGetPlaneCount(image)
        return planes == 0
            ? [CVPixelBufferGetHeight(image) * CVPixelBufferGetBytesPerRow(image)]
            : (0..<planes).map { CVPixelBufferGetHeightOfPlane(image, $0) * CVPixelBufferGetBytesPerRowOfPlane(image, $0) }
    }

    init(folder: URL, reading: Bool = false, layout: Layout? = nil) throws {
        url = folder.appending(path: ".capture-frames")
        descriptor = open(url.path, reading ? O_RDONLY : O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw Self.fileError() }
        if let data = layout?.attachments,
           let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dictionary = values as? [String: Any] {
            attachments = dictionary as CFDictionary
        }
    }

    deinit { close(descriptor) }

    func append(_ image: CVPixelBuffer) throws {
        if attachments == nil { attachments = CVBufferCopyAttachments(image, .shouldPropagate) }
        try withPlanes(image, flags: .readOnly) { base, count in
            try transfer(base, count: count, reading: false)
        }
    }

    func rewind() throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw Self.fileError() }
    }

    func read(into image: CVPixelBuffer) throws {
        if let attachments { CVBufferSetAttachments(image, attachments, .shouldPropagate) }
        try withPlanes(image, flags: []) { base, count in
            try transfer(base, count: count, reading: true)
        }
    }

    func discard() throws {
        try FileManager.default.removeItem(at: url)
    }

    private func withPlanes(_ image: CVPixelBuffer, flags: CVPixelBufferLockFlags,
                            operation: (UnsafeMutableRawPointer, Int) throws -> Void) throws {
        guard CVPixelBufferLockBaseAddress(image, flags) == kCVReturnSuccess else {
            throw CaptureError.message("一時保存フレームのメモリを参照できません")
        }
        defer { CVPixelBufferUnlockBaseAddress(image, flags) }
        let count = CVPixelBufferGetPlaneCount(image)
        if count == 0 {
            guard let base = CVPixelBufferGetBaseAddress(image) else { throw Self.fileError() }
            try operation(base, CVPixelBufferGetHeight(image) * CVPixelBufferGetBytesPerRow(image))
        } else {
            for plane in 0..<count {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(image, plane) else { throw Self.fileError() }
                try operation(base, CVPixelBufferGetHeightOfPlane(image, plane) * CVPixelBufferGetBytesPerRowOfPlane(image, plane))
            }
        }
    }

    private func transfer(_ base: UnsafeMutableRawPointer, count: Int, reading: Bool) throws {
        var offset = 0
        while offset < count {
            let remaining = count - offset
            let pointer = base.advanced(by: offset)
            let transferred = reading ? Darwin.read(descriptor, pointer, remaining) : Darwin.write(descriptor, pointer, remaining)
            if transferred < 0 && errno == EINTR { continue }
            if transferred == 0 {
                throw CaptureError.message("一時保存フレームを読み切れません")
            }
            guard transferred > 0 else { throw Self.fileError() }
            offset += transferred
        }
    }

    private static func fileError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
