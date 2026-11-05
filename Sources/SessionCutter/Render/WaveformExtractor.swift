import AVFoundation
import Foundation

/// A peak envelope of one audio file, fine enough to sync by eye.
///
/// The fine level holds one peak per five milliseconds — eight per frame at
/// 25 fps — so zooming in reveals actual transients: a door, a cut, a plosive.
/// The coarse level is a pre-folded copy for wide views, so a two-hour lane
/// never asks the fine level for a million maxima per redraw.
struct Waveform: Sendable {
    /// Fine buckets per second. Nominally 200; a little lower only when a
    /// very long file hits the bucket cap.
    var rate: Double
    var fine: [Float]
    /// One value per `coarseFactor` fine buckets, each their maximum.
    var coarse: [Float]

    static let coarseFactor = 64

    /// The loudest moment between two times on the file's own clock. Ranges
    /// outside the file are silent, not an error — lanes routinely start
    /// before or after the visible window.
    func peak(from start: Double, to end: Double) -> Float {
        guard !fine.isEmpty, end > 0 else { return 0 }
        let lower = max(Int(start * rate), 0)
        let upper = min(max(Int(end * rate) + 1, lower + 1), fine.count)
        guard lower < fine.count else { return 0 }

        // Wide ranges read the folded copy; the edges lose nothing that a
        // one-pixel column could have shown anyway.
        if upper - lower > Self.coarseFactor * 2, !coarse.isEmpty {
            let coarseLower = min(lower / Self.coarseFactor, coarse.count - 1)
            let coarseUpper = min(max(upper / Self.coarseFactor, coarseLower + 1), coarse.count)
            var peak: Float = 0
            for index in coarseLower..<coarseUpper {
                peak = max(peak, coarse[index])
            }
            return peak
        }

        var peak: Float = 0
        for index in lower..<upper {
            peak = max(peak, fine[index])
        }
        return peak
    }
}

/// Reads peak envelopes for the timeline. Decoding is read-only and never
/// touches the source file.
enum WaveformExtractor {
    /// Five milliseconds per bucket.
    private static let bucketsPerSecond = 200.0
    /// Just under three hours at full rate; longer files get proportionally
    /// coarser buckets rather than unbounded memory.
    private static let bucketCap = 2_000_000

    /// Returns the file's envelope, or nil when it cannot be decoded.
    static func waveform(url: URL) async -> Waveform? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero)
        guard duration.isFinite, duration > 0 else { return nil }

        let bucketCount = min(max(Int(duration * bucketsPerSecond), 1), bucketCap)
        let rate = Double(bucketCount) / duration

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
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
            if Task.isCancelled { return nil }
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

        guard reader.status == .completed || reader.status == .reading else { return nil }

        normalise(&peaks)
        return Waveform(rate: rate, fine: peaks, coarse: fold(peaks))
    }

    /// Scales the envelope so its loud passages reach full height. Lining up
    /// a camera track against a mastered mix is a comparison of shapes, and
    /// shapes only match visually when both are drawn at full size — the
    /// files' absolute levels differ by tens of decibels. The anchor is the
    /// 99.5th percentile, so one clap or two-pop cannot flatten the dialogue.
    private static func normalise(_ peaks: inout [Float]) {
        let sorted = peaks.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return }
        let anchor = sorted[min(Int(Double(sorted.count) * 0.995), sorted.count - 1)]
        guard anchor > 0 else { return }
        for index in peaks.indices {
            peaks[index] = min(peaks[index] / anchor, 1)
        }
    }

    private static func fold(_ peaks: [Float]) -> [Float] {
        let factor = Waveform.coarseFactor
        var result: [Float] = []
        result.reserveCapacity(peaks.count / factor + 1)
        var index = 0
        while index < peaks.count {
            let end = min(index + factor, peaks.count)
            var peak: Float = 0
            for value in peaks[index..<end] {
                peak = max(peak, value)
            }
            result.append(peak)
            index = end
        }
        return result
    }
}
