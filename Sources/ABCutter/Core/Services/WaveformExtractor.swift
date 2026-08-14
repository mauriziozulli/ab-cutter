import AVFoundation
import Foundation

/// A coarse peak envelope used to eyeball sync in the timeline. Decoding is
/// read-only and never touches the source file.
enum WaveformExtractor {
    /// Returns `bucketCount` peak values in 0 … 1, one per horizontal slice of
    /// the file. Returns an empty array when the file cannot be decoded.
    static func peaks(url: URL, bucketCount: Int = 900) async -> [Float] {
        guard bucketCount > 0 else { return [] }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        guard duration.isFinite, duration > 0 else { return [] }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        defer { reader.cancelReading() }

        var peaks = [Float](repeating: 0, count: bucketCount)
        var seenFloats = 0

        // Total sample count is only approximate; the bucket index is clamped
        // so a slightly long or short file still fills the envelope.
        let format = (try? await track.load(.formatDescriptions))?.first
        let basic = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = Int(basic?.mChannelsPerFrame ?? 2)
        let sampleRate = basic?.mSampleRate ?? 48_000
        let expectedFloats = max(Int(duration * sampleRate) * max(channels, 1), 1)

        while let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { return [] }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }

            var totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &totalLength,
                dataPointerOut: &pointer
            ) == kCMBlockBufferNoErr, let pointer, totalLength >= 4 else { continue }

            let floatCount = totalLength / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { samples in
                for index in 0..<floatCount {
                    let bucket = min(bucketCount - 1, (seenFloats + index) * bucketCount / expectedFloats)
                    let magnitude = abs(samples[index])
                    if magnitude > peaks[bucket] { peaks[bucket] = magnitude }
                }
            }
            seenFloats += floatCount
        }

        guard reader.status == .completed || reader.status == .reading else { return [] }
        return peaks
    }
}
