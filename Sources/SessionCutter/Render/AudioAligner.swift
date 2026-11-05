import AVFoundation
import CoreMedia
import Foundation

enum AlignError: LocalizedError {
    case videoHasNoAudio
    case sourceUnreadable
    case tooLittleOverlap
    case noConfidentMatch

    var errorDescription: String? {
        switch self {
        case .videoHasNoAudio:
            return "Das Video hat keine eigene Tonspur — ohne Referenz gibt es nichts zu vergleichen."
        case .sourceUnreadable:
            return "Diese Tonspur konnte nicht dekodiert werden."
        case .tooLittleOverlap:
            return "Die beiden Spuren überlappen sich keine fünf Sekunden."
        case .noConfidentMatch:
            return "Keine verlässliche Übereinstimmung gefunden. Passt die Datei zu diesem Film?"
        }
    }
}

/// Where a mix belongs under the picture, read out of the sound itself.
struct AlignmentResult: Sendable {
    /// Seconds from the first frame of the picture — the app's offset
    /// convention. Negative means the mix starts before the picture does.
    var offsetSeconds: Double
    /// Normalised correlation at the winning lag, 0 … 1. Below about 0.25
    /// the match is a guess, and the caller says so instead of placing it.
    var confidence: Double
}

/// Syncs a mix to the film by the sound itself.
///
/// A delivery without a two-pop still carries its sync reference: the film's
/// own embedded track and the mix contain the same dialogue and atmos, so
/// cross-correlating the two envelopes finds the offset the two-pop would
/// have marked. Two stages — a coarse pass over everything at 12.5 Hz, then
/// a fine pass at 200 Hz around the winner — land within ±5 ms, a quarter
/// frame at 50 fps and far inside a frame at 24/25.
///
/// Everything here reads audio; nothing writes. Analysis is capped at the
/// first twelve minutes of each file, which bounds memory and is more sync
/// evidence than any two-pop ever offered.
enum AudioAligner {
    /// The decode rate. 8 kHz is AVFoundation's floor for an audio-mix
    /// output — anything lower is rejected at init — and is still far more
    /// than the 200 Hz envelope needs.
    private static let sampleRate = 8_000.0
    private static let envelopeRate = 200.0
    private static let coarseRate = 12.5
    private static let analysisCapSeconds = 12.0 * 60.0
    private static let minimumOverlapSeconds = 5.0
    /// Below this the winning lag is reported as a failure, not a sync.
    static let confidenceFloor = 0.25

    /// Finds where `sourceURL` sits relative to the video's embedded track.
    static func align(sourceURL: URL, videoURL: URL) async throws -> AlignmentResult {
        async let videoSamples = monoSamples(url: videoURL)
        async let sourceSamples = monoSamples(url: sourceURL)

        guard let reference = try await videoSamples else { throw AlignError.videoHasNoAudio }
        guard let candidate = try await sourceSamples else { throw AlignError.sourceUnreadable }

        let referenceEnvelope = envelope(reference, decimateBy: Int(sampleRate / envelopeRate))
        let candidateEnvelope = envelope(candidate, decimateBy: Int(sampleRate / envelopeRate))

        let coarseFactor = Int(envelopeRate / coarseRate)
        let referenceCoarse = envelope(referenceEnvelope, decimateBy: coarseFactor)
        let candidateCoarse = envelope(candidateEnvelope, decimateBy: coarseFactor)

        let minimumOverlapCoarse = Int(minimumOverlapSeconds * coarseRate)
        guard referenceCoarse.count > minimumOverlapCoarse,
              candidateCoarse.count > minimumOverlapCoarse else {
            throw AlignError.tooLittleOverlap
        }

        // Stage 1: every plausible lag, coarsely. The bounds get names not
        // just for the reader: a unary minus right before `...` is parsed
        // differently across Swift versions, and this form is unambiguous
        // in all of them.
        let earliestLag = minimumOverlapCoarse - candidateCoarse.count
        let latestLag = referenceCoarse.count - minimumOverlapCoarse
        let coarse = bestLag(
            reference: meanCentred(referenceCoarse),
            candidate: meanCentred(candidateCoarse),
            lags: earliestLag...latestLag,
            minimumOverlap: minimumOverlapCoarse
        )

        // Stage 2: ±1 s around the winner, finely.
        let centre = Int((Double(coarse.lag) / coarseRate * envelopeRate).rounded())
        let window = Int(envelopeRate)
        let fine = bestLag(
            reference: meanCentred(referenceEnvelope),
            candidate: meanCentred(candidateEnvelope),
            lags: (centre - window)...(centre + window),
            minimumOverlap: Int(minimumOverlapSeconds * envelopeRate)
        )

        guard fine.score >= confidenceFloor else { throw AlignError.noConfidentMatch }
        return AlignmentResult(
            offsetSeconds: Double(fine.lag) / envelopeRate,
            confidence: fine.score
        )
    }

    // MARK: - Correlation

    /// The lag with the highest normalised correlation. A lag is where the
    /// candidate's first sample lands on the reference's timeline, so a
    /// positive lag means the mix starts after the picture.
    private static func bestLag(
        reference: [Float],
        candidate: [Float],
        lags: ClosedRange<Int>,
        minimumOverlap: Int
    ) -> (lag: Int, score: Double) {
        var bestLag = 0
        var bestScore = -Double.infinity

        for lag in lags.lowerBound...lags.upperBound {
            // Overlapping index range in reference coordinates.
            let start = max(lag, 0)
            let end = min(reference.count, candidate.count + lag)
            let overlap = end - start
            guard overlap >= minimumOverlap else { continue }

            var dot: Double = 0
            var energyReference: Double = 0
            var energyCandidate: Double = 0
            for index in start..<end {
                let r = Double(reference[index])
                let c = Double(candidate[index - lag])
                dot += r * c
                energyReference += r * r
                energyCandidate += c * c
            }

            let denominator = (energyReference * energyCandidate).squareRoot()
            guard denominator > 0 else { continue }
            let score = dot / denominator
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        return (bestLag, bestScore.isFinite ? bestScore : 0)
    }

    private static func meanCentred(_ values: [Float]) -> [Float] {
        guard !values.isEmpty else { return values }
        let mean = values.reduce(Float(0), +) / Float(values.count)
        return values.map { $0 - mean }
    }

    /// Max-of-abs per block: loudness structure, which is what survives a
    /// mix. A mix is not the original signal — levels, EQ and added music
    /// differ — but the dialogue's rhythm is the same in both, and that is
    /// what the envelope keeps.
    private static func envelope(_ samples: [Float], decimateBy factor: Int) -> [Float] {
        guard factor > 1 else { return samples.map { abs($0) } }
        var result: [Float] = []
        result.reserveCapacity(samples.count / factor + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + factor, samples.count)
            var peak: Float = 0
            for sample in samples[index..<end] {
                peak = max(peak, abs(sample))
            }
            result.append(peak)
            index = end
        }
        return result
    }

    // MARK: - Decoding

    /// The first audio track as mono floats at the analysis rate, or nil when
    /// there is no audio track at all. The audio-mix output does the channel
    /// fold and the resample, so every input format arrives the same shape.
    private static func monoSamples(url: URL) async throws -> [Float]? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AlignError.sourceUnreadable
        }

        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AlignError.sourceUnreadable }
        reader.add(output)
        guard reader.startReading() else { throw AlignError.sourceUnreadable }
        defer { reader.cancelReading() }

        let cap = Int(analysisCapSeconds * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(min(cap, 1_000_000))

        while samples.count < cap, let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled { throw CancellationError() }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &length,
                dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                let take = min(count, cap - samples.count)
                samples.append(contentsOf: UnsafeBufferPointer(start: floats, count: take))
            }
        }

        guard !samples.isEmpty else { throw AlignError.sourceUnreadable }
        return samples
    }
}
