import CoreMedia
import CoreVideo
import Darwin

// The encoder may retain its surfaces after append returns. A separate pool
// lets the camera recycle its capture surfaces as soon as the delegate returns.
final class EncoderBuffers {
    private let pool: CVPixelBufferPool
    private let width: Int
    private let height: Int
    private let pixelFormat: OSType
    private let maximumBuffers: Int

    init(source: CVPixelBuffer, maximumBuffers: Int = 32) throws {
        self.maximumBuffers = maximumBuffers
        width = CVPixelBufferGetWidth(source)
        height = CVPixelBufferGetHeight(source)
        pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let pixelAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: 12]
        var pool: CVPixelBufferPool?
        let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary,
                                             pixelAttributes as CFDictionary, &pool)
        guard result == kCVReturnSuccess, let pool else {
            throw CaptureError.message("エンコーダー用バッファを確保できません (\(result))")
        }
        self.pool = pool
    }

    func copy(_ source: CVPixelBuffer) throws -> CVPixelBuffer? {
        guard CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height,
              CVPixelBufferGetPixelFormatType(source) == pixelFormat else {
            throw CaptureError.message("録画中にカメラの画素形式が変わりました")
        }
        guard let destination = try allocate() else { return nil }
        try copyPixels(from: source, to: destination)
        CVBufferPropagateAttachments(source, destination)

        return destination
    }

    func allocate() throws -> CVPixelBuffer? {
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: maximumBuffers]
        var destination: CVPixelBuffer?
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                                                                              limit as CFDictionary, &destination)
        if allocation == kCVReturnWouldExceedAllocationThreshold { return nil }
        guard allocation == kCVReturnSuccess, let destination else {
            throw CaptureError.message("フレーム用バッファを確保できません (\(allocation))")
        }
        return destination
    }

    private func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
            throw CaptureError.message("カメラの画素バッファを読み取れません")
        }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw CaptureError.message("エンコーダーの画素バッファに書き込めません")
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            try copyPlane(source: CVPixelBufferGetBaseAddress(source), destination: CVPixelBufferGetBaseAddress(destination),
                          sourceStride: CVPixelBufferGetBytesPerRow(source), destinationStride: CVPixelBufferGetBytesPerRow(destination),
                          rows: height)
        } else {
            for plane in 0..<planes {
                try copyPlane(source: CVPixelBufferGetBaseAddressOfPlane(source, plane),
                              destination: CVPixelBufferGetBaseAddressOfPlane(destination, plane),
                              sourceStride: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                              destinationStride: CVPixelBufferGetBytesPerRowOfPlane(destination, plane),
                              rows: CVPixelBufferGetHeightOfPlane(source, plane))
            }
        }
    }

    private func copyPlane(source: UnsafeMutableRawPointer?, destination: UnsafeMutableRawPointer?,
                           sourceStride: Int, destinationStride: Int, rows: Int) throws {
        guard let source, let destination else { throw CaptureError.message("画素のメモリを参照できません") }
        if sourceStride == destinationStride {
            memcpy(destination, source, rows * sourceStride)
        } else {
            let bytes = min(sourceStride, destinationStride)
            for row in 0..<rows {
                memcpy(destination.advanced(by: row * destinationStride), source.advanced(by: row * sourceStride), bytes)
            }
        }
    }
}
