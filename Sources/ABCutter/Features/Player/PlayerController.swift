import AVFoundation
import Combine
import CoreMedia
import Foundation

/// What the preview monitors while playing.
enum MonitorMode: Equatable {
    /// One audio source, heard for the whole timeline.
    case single(UUID)
    /// Exactly what an export would do: before-source, then after-source.
    case followSplit
}

/// Drives the preview player: builds the timeline composition, switches audio
/// live, and can show the finished social framing and grade before exporting.
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?

    @Published var monitorMode: MonitorMode = .followSplit
    /// When set, the preview is cropped and graded like the export.
    @Published var previewFormat: SocialFormat?
    /// Stops playback at the end of the selected clip.
    @Published var limitToClip = true

    /// Frame furniture for the selected clip, built asynchronously by
    /// `AppState` so the preview shows what the export will.
    var previewOverlays = ClipOverlays.empty

    /// True while the player is showing one clip exactly as the export builds
    /// it — loop passes and A/B mix included — instead of the raw timeline.
    @Published private(set) var isClipPreview = false

    private var timeline: TimelineComposition?
    private var timeObserver: Any?
    private var playbackLimit: ClosedRange<Double>?
    /// Guards against a slow rebuild overwriting a newer one.
    private var buildToken = 0

    init() {
        player.actionAtItemEnd = .pause
        player.volume = 1
        installTimeObserver()
    }

    // The controller lives for as long as the app does, so the periodic
    // observer is never torn down — a nonisolated deinit cannot safely reach
    // main-actor state to remove it.

    // MARK: - Loading

    /// Rebuilds the composition. Call after the video, an audio source or a
    /// sync offset changes.
    func reload(project: ABProject, selectedClip: Clip?) async {
        isClipPreview = false
        guard project.hasVideo else {
            player.replaceCurrentItem(with: nil)
            timeline = nil
            duration = 0
            return
        }

        buildToken += 1
        let token = buildToken
        isPreparing = true
        errorMessage = nil

        do {
            let built = try await CompositionBuilder.buildTimeline(project: project)
            guard token == buildToken else { return }

            timeline = built
            let item = AVPlayerItem(asset: built.composition)
            let resumeAt = currentTime
            player.replaceCurrentItem(with: item)
            duration = CMTimeGetSeconds(built.duration)
            apply(project: project, selectedClip: selectedClip)
            if resumeAt > 0, resumeAt < duration {
                seek(to: resumeAt)
            }
        } catch {
            guard token == buildToken else { return }
            errorMessage = error.localizedDescription
            player.replaceCurrentItem(with: nil)
            timeline = nil
            duration = 0
        }

        if token == buildToken {
            isPreparing = false
        }
    }

    /// Applies monitoring, framing and grade without rebuilding the tracks.
    func apply(project: ABProject, selectedClip: Clip?) {
        // The clip preview carries its own composition and mix; styling it
        // with the timeline's would silently show the wrong thing.
        guard !isClipPreview else { return }
        guard let timeline, let item = player.currentItem else { return }

        item.audioMix = makeAudioMix(project: project, clip: selectedClip, timeline: timeline)
        item.videoComposition = makeVideoComposition(project: project, clip: selectedClip, timeline: timeline)

        if limitToClip, let selectedClip, selectedClip.duration > 0 {
            playbackLimit = selectedClip.start...selectedClip.end
        } else {
            playbackLimit = nil
        }

        // An audio mix swapped mid-flight is not picked up until the item
        // re-reads its timeline, and audio is already rendered ahead of the
        // playhead — so the swap has to be followed by a seek to flush it.
        // Playback is restarted afterwards, or the nudge would silently stop
        // the transport every time a control moved.
        let wasPlaying = isPlaying
        player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard wasPlaying, let self else { return }
            self.player.play()
        }
    }

    // MARK: - Clip preview

    /// Plays the selected clip exactly as it will be exported: the clip
    /// composition, its audio mix, and its own look — for a loop clip that
    /// includes both passes, which the raw timeline cannot show at all.
    /// Cards are left out; they belong to the delivery, not to the cut.
    func loadClipPreview(project: ABProject, clip: Clip) async {
        guard project.hasVideo else { return }

        buildToken += 1
        let token = buildToken
        isPreparing = true
        errorMessage = nil

        do {
            let built = try await CompositionBuilder.buildClip(project: project, clip: clip)
            guard token == buildToken else { return }

            let look = clip.look
            let format = previewFormat ?? .portrait916
            let plan = RenderPlan(
                targetSize: format.size,
                fitMode: look.fitMode,
                panX: clip.panX,
                panY: clip.panY,
                switchTimes: built.switchTimes,
                beforeLook: look.beforeLook,
                afterLook: look.afterLook,
                frameTreatment: look.frameTreatment,
                frameBackdrop: look.frameBackdrop,
                insetScale: look.insetScale,
                labelPosition: look.labelPosition,
                safeArea: project.export.safeArea(for: format),
                showStrips: look.showStrips,
                grainStrength: look.grainStrength,
                vignetteStrength: look.vignetteStrength,
                beforeOverlay: previewOverlays.before,
                afterOverlay: previewOverlays.after,
                pictureRange: built.pictureRange,
                sourceNaturalSize: built.videoNaturalSize,
                sourcePreferredTransform: built.videoPreferredTransform
            )

            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            let videoComposition = AVMutableVideoComposition(asset: built.composition) { filterRequest in
                let output = FrameRenderer.render(
                    filterRequest.sourceImage,
                    at: filterRequest.compositionTime,
                    plan: plan
                )
                filterRequest.finish(with: output, context: nil)
            }
            videoComposition.renderSize = format.size
            videoComposition.frameDuration = built.frameDuration
            item.videoComposition = videoComposition

            // The clip preview has its own short timeline; the project's
            // playhead limit would stop it a frame in.
            playbackLimit = nil
            isClipPreview = true
            player.replaceCurrentItem(with: item)
            duration = CMTimeGetSeconds(built.duration)
            seek(to: 0)
        } catch {
            guard token == buildToken else { return }
            errorMessage = error.localizedDescription
        }

        if token == buildToken {
            isPreparing = false
        }
    }

    /// Back to the project timeline.
    func exitClipPreview(project: ABProject, selectedClip: Clip?) async {
        guard isClipPreview else { return }
        isClipPreview = false
        await reload(project: project, selectedClip: selectedClip)
    }

    // MARK: - Mixing

    /// Volume automation for the preview. It mirrors the exporter's exactly —
    /// the same alternating ramps at the same points — so what is heard while
    /// scrubbing is what lands in the file.
    private func makeAudioMix(project: ABProject, clip: Clip?, timeline: TimelineComposition) -> AVAudioMix? {
        guard !timeline.audioTracks.isEmpty else { return nil }

        func gain(_ id: UUID?) -> Float {
            guard let source = project.source(withID: id) else { return 1 }
            return Float(pow(10.0, source.gainDB / 20.0))
        }

        // Resolve the pair even with no clip selected, so the default monitor
        // mode is never silent just because nothing has been marked yet.
        let beforeID = clip.flatMap { project.beforeSource(for: $0)?.id }
            ?? project.defaultBeforeSourceID
            ?? project.audioSources.first?.id
        let afterID = clip.flatMap { project.afterSource(for: $0)?.id }
            ?? project.defaultAfterSourceID
            ?? beforeID

        var parameters: [AVMutableAudioMixInputParameters] = []

        switch monitorMode {
        case .single(let soloID):
            // A solo of a source that has since gone falls back to the A side
            // rather than muting everything.
            let audible = timeline.audioTracks[soloID] != nil ? soloID : beforeID
            for (sourceID, track) in timeline.audioTracks {
                let params = AVMutableAudioMixInputParameters(track: track)
                params.setVolume(sourceID == audible ? gain(sourceID) : 0, at: .zero)
                parameters.append(params)
            }

        case .followSplit:
            let switchTimes = (clip?.switches ?? []).map {
                CMTime(seconds: $0, preferredTimescale: 90_000)
            }
            let fade = CMTime(
                seconds: max((clip?.look.audioCrossfadeMilliseconds ?? 40), 0) / 1000.0,
                preferredTimescale: 90_000
            )

            for (sourceID, track) in timeline.audioTracks {
                if sourceID == beforeID, beforeID == afterID {
                    // Only one source in play: nothing to switch between.
                    let params = AVMutableAudioMixInputParameters(track: track)
                    params.setVolume(gain(sourceID), at: .zero)
                    parameters.append(params)
                } else if sourceID == beforeID || sourceID == afterID {
                    parameters.append(
                        CompositionBuilder.alternatingParameters(
                            track: track,
                            gain: gain(sourceID),
                            switchTimes: switchTimes,
                            fade: fade,
                            startsAudible: sourceID == beforeID
                        )
                    )
                } else {
                    let params = AVMutableAudioMixInputParameters(track: track)
                    params.setVolume(0, at: .zero)
                    parameters.append(params)
                }
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func makeVideoComposition(
        project: ABProject,
        clip: Clip?,
        timeline: TimelineComposition
    ) -> AVVideoComposition? {
        guard let previewFormat else { return nil }

        // The preview runs on the whole timeline, so the split is absolute
        // project time rather than clip-relative. The look belongs to the
        // selected clip; without one the film runs plain and full bleed.
        let look = clip?.look ?? ClipLook()
        let plan = RenderPlan(
            targetSize: previewFormat.size,
            fitMode: look.fitMode,
            panX: clip?.panX ?? 0,
            panY: clip?.panY ?? 0,
            switchTimes: (clip?.switches ?? []).map {
                CMTime(seconds: $0, preferredTimescale: 90_000)
            },
            beforeLook: clip == nil ? look.afterLook : look.beforeLook,
            afterLook: look.afterLook,
            frameTreatment: clip == nil ? .fullBleed : look.frameTreatment,
            frameBackdrop: look.frameBackdrop,
            insetScale: look.insetScale,
            labelPosition: look.labelPosition,
            safeArea: project.export.safeArea(for: previewFormat),
            showStrips: clip == nil ? false : look.showStrips,
            grainStrength: clip == nil ? 0 : look.grainStrength,
            vignetteStrength: clip == nil ? 0 : look.vignetteStrength,
            beforeOverlay: previewOverlays.before,
            afterOverlay: previewOverlays.after,
            sourceNaturalSize: timeline.videoNaturalSize,
            sourcePreferredTransform: timeline.videoPreferredTransform
        )

        let composition = AVMutableVideoComposition(asset: timeline.composition) { filterRequest in
            let output = FrameRenderer.render(
                filterRequest.sourceImage,
                at: filterRequest.compositionTime,
                plan: plan
            )
            filterRequest.finish(with: output, context: nil)
        }
        composition.renderSize = previewFormat.size
        composition.frameDuration = timeline.frameDuration
        return composition
    }

    // MARK: - Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        if let playbackLimit, currentTime >= playbackLimit.upperBound - 0.01 {
            seek(to: playbackLimit.lowerBound)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        currentTime = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func step(frames: Int, frameRate: FrameRate) {
        seek(to: currentTime + Double(frames) / frameRate.fps)
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds

                if let limit = self.playbackLimit, self.isPlaying, seconds >= limit.upperBound {
                    self.pause()
                    self.seek(to: limit.upperBound)
                }
            }
        }
    }
}
