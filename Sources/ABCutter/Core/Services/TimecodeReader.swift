import AVFoundation
import CoreMedia
import Foundation

/// Where a start timecode came from, so the UI can be honest about it.
enum TimecodeOrigin: String, Sendable {
    case broadcastWave
    case quickTimeTrack
    case none

    var title: String {
        switch self {
        case .broadcastWave: "BWF time reference"
        case .quickTimeTrack: "Timecode track"
        case .none: "No timecode"
        }
    }
}

struct StartTimecode: Sendable {
    /// Seconds since timecode midnight.
    var seconds: Double
    var origin: TimecodeOrigin
    /// Frame buckets reported by a QuickTime timecode track, when present.
    var frameQuanta: Int?
}

/// Reads the start-of-media timecode from the two places it actually lives in
/// post-production deliveries: the Broadcast Wave `bext` chunk of a WAV, and
/// the QuickTime `tmcd` track of a MOV/MP4.
enum TimecodeReader {
    private static let waveExtensions: Set<String> = ["wav", "bwf", "wave", "rf64", "w64"]

    /// Best available start timecode for any media file.
    static func startTimecode(for url: URL, asset: AVAsset? = nil) async -> StartTimecode? {
        if waveExtensions.contains(url.pathExtension.lowercased()),
           let seconds = broadcastWaveStartSeconds(url: url) {
            return StartTimecode(seconds: seconds, origin: .broadcastWave, frameQuanta: nil)
        }
        let asset = asset ?? AVURLAsset(url: url)
        if let track = await quickTimeStart(asset: asset) {
            return track
        }
        // A WAV without a readable header extension still gets a second chance.
        if let seconds = broadcastWaveStartSeconds(url: url) {
            return StartTimecode(seconds: seconds, origin: .broadcastWave, frameQuanta: nil)
        }
        return nil
    }

    // MARK: - QuickTime timecode track

    /// Reads the first `tmcd` sample. The stored value is a frame counter that
    /// increments once per real frame, so multiplying by the track's frame
    /// duration yields elapsed seconds — correct for drop-frame too, because
    /// drop-frame skips *labels*, not frames.
    static func quickTimeStart(asset: AVAsset) async -> StartTimecode? {
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }

        guard let sample = output.copyNextSampleBuffer(),
              let formatDescription = CMSampleBufferGetFormatDescription(sample),
              let blockBuffer = CMSampleBufferGetDataBuffer(sample)
        else { return nil }

        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return nil }

        let subType = CMFormatDescriptionGetMediaSubType(formatDescription)
        let frameNumber: Int64

        switch subType {
        case kCMTimeCodeFormatType_TimeCode32 where totalLength >= 4:
            var raw: UInt32 = 0
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: UnsafeRawBufferPointer(start: pointer, count: 4)) }
            frameNumber = Int64(UInt32(bigEndian: raw))
        case kCMTimeCodeFormatType_TimeCode64 where totalLength >= 8:
            var raw: UInt64 = 0
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: UnsafeRawBufferPointer(start: pointer, count: 8)) }
            frameNumber = Int64(bitPattern: UInt64(bigEndian: raw))
        default:
            return nil
        }

        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(formatDescription)
        let frameSeconds = CMTimeGetSeconds(frameDuration)
        guard frameSeconds.isFinite, frameSeconds > 0, frameNumber >= 0 else { return nil }

        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(formatDescription))
        return StartTimecode(
            seconds: Double(frameNumber) * frameSeconds,
            origin: .quickTimeTrack,
            frameQuanta: quanta > 0 ? quanta : nil
        )
    }

    // MARK: - Broadcast Wave

    /// Walks the RIFF chunk list for `fmt ` and `bext`, and returns the
    /// `TimeReference` (samples since midnight) converted to seconds.
    /// Handles RF64/BW64 containers, where the 64-bit sizes live in `ds64`.
    static func broadcastWaveStartSeconds(url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize >= 12 else { return nil }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return nil }

        let containerID = header.ascii(at: 0, length: 4)
        let waveID = header.ascii(at: 8, length: 4)
        guard ["RIFF", "RF64", "BW64"].contains(containerID), waveID == "WAVE" else { return nil }

        var sampleRate: Double?
        var timeReferenceSamples: UInt64?
        var offset: UInt64 = 12

        while offset + 8 <= fileSize {
            try? handle.seek(toOffset: offset)
            guard let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8 else { break }

            let chunkID = chunkHeader.ascii(at: 0, length: 4)
            let declaredSize = UInt64(chunkHeader.uint32LE(at: 4))
            let payloadOffset = offset + 8
            let available = fileSize > payloadOffset ? fileSize - payloadOffset : 0
            let readableSize = min(declaredSize, available)

            switch chunkID {
            case "fmt ":
                if readableSize >= 16,
                   let data = try? handle.read(upToCount: Int(min(readableSize, 64))),
                   data.count >= 16 {
                    let rate = data.uint32LE(at: 4)
                    if rate > 0 { sampleRate = Double(rate) }
                }
            case "bext":
                if readableSize >= 346,
                   let data = try? handle.read(upToCount: Int(min(readableSize, 602))),
                   data.count >= 346 {
                    let low = UInt64(data.uint32LE(at: 338))
                    let high = UInt64(data.uint32LE(at: 342))
                    timeReferenceSamples = (high << 32) | low
                }
            default:
                break
            }

            if sampleRate != nil, timeReferenceSamples != nil { break }

            let paddedSize = declaredSize + (declaredSize % 2)
            guard paddedSize <= UInt64.max - payloadOffset else { break }
            let nextOffset = payloadOffset + paddedSize
            if nextOffset <= offset || nextOffset > fileSize { break }
            offset = nextOffset
        }

        guard let sampleRate, sampleRate > 0, let timeReferenceSamples else { return nil }
        // A zero time reference means "not stamped", not "midnight".
        guard timeReferenceSamples > 0 else { return nil }
        return Double(timeReferenceSamples) / sampleRate
    }
}

// MARK: - Little-endian byte helpers

extension Data {
    func ascii(at index: Int, length: Int) -> String {
        guard index >= 0, count >= index + length else { return "" }
        let bytes = subdata(in: (startIndex + index)..<(startIndex + index + length))
        return String(decoding: bytes, as: UTF8.self)
    }

    func uint32LE(at index: Int) -> UInt32 {
        guard index >= 0, count >= index + 4 else { return 0 }
        var value: UInt32 = 0
        for byte in 0..<4 {
            value |= UInt32(self[startIndex + index + byte]) << (8 * byte)
        }
        return value
    }
}
