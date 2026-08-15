import SwiftUI

/// The strip under the picture: a ruler, one lane per audio layer with its
/// peak envelope, and the clip regions with their A/B split marks.
///
/// Dragging a lane slides that layer in time, which is the manual sync when a
/// file carries no timecode.
@MainActor
struct TimelineView: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: PlayerController

    private let rulerHeight: CGFloat = 22
    private let clipLaneHeight: CGFloat = 26
    private let laneHeight: CGFloat = 40

    /// What a drag on the clip lane grabbed, captured once when it starts so
    /// every subsequent delta is measured from the same origin.
    private struct ClipDrag {
        enum Handle {
            case move
            case trimIn
            case trimOut
            case split
        }

        var clipID: UUID
        var handle: Handle
        var originStart: Double
        var originEnd: Double
        var originSplit: Double
    }

    @State private var clipDrag: ClipDrag?

    /// Seconds covered by the whole visible strip.
    private var visibleDuration: Double {
        max(state.project.timelineDuration / max(state.zoom, 1), 1)
    }

    /// Left edge of the visible window, kept centred on the playhead.
    private var windowStart: Double {
        let total = state.project.timelineDuration
        let visible = visibleDuration
        guard visible < total else { return 0 }
        return min(max(player.currentTime - visible / 2, 0), total - visible)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        draw(context: context, size: size)
                    }
                    .contentShape(Rectangle())
                    .gesture(scrubGesture(width: width))

                    laneDragOverlay(width: width)
                    playheadOverlay(width: width)
                }
            }
            .frame(height: totalHeight)
            .background(Theme.panelBackground)
        }
    }

    private var totalHeight: CGFloat {
        rulerHeight + clipLaneHeight + laneHeight * CGFloat(max(visibleSources.count, 1)) + 8
    }

    private var visibleSources: [AudioSource] {
        state.project.audioSources
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Zeitleiste")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Spacer()

            Image(systemName: "minus.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $state.zoom, in: 1...400)
                .controlSize(.mini)
                .frame(width: 150)
            Image(systemName: "plus.magnifyingglass")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(zoomLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 5)
    }

    private var zoomLabel: String {
        let visible = visibleDuration
        if visible < 60 { return String(format: "%.1f s", visible) }
        return String(format: "%.0f Min", visible / 60)
    }

    // MARK: - Coordinate mapping

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        let visible = visibleDuration
        return CGFloat((seconds - windowStart) / visible) * width
    }

    private func seconds(forX x: CGFloat, width: CGFloat) -> Double {
        windowStart + Double(x / max(width, 1)) * visibleDuration
    }

    // MARK: - Drawing

    private func draw(context: GraphicsContext, size: CGSize) {
        let width = size.width
        drawRuler(context: context, width: width)
        drawClipLane(context: context, width: width)

        var y = rulerHeight + clipLaneHeight
        for source in visibleSources {
            drawLane(context: context, source: source, width: width, top: y)
            y += laneHeight
        }
    }

    private func drawRuler(context: GraphicsContext, width: CGFloat) {
        let visible = visibleDuration
        let step = tickStep(for: visible)
        var tick = (windowStart / step).rounded(.down) * step

        while tick <= windowStart + visible {
            let position = x(for: tick, width: width)
            if position >= 0, position <= width {
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: position, y: rulerHeight - 6))
                        path.addLine(to: CGPoint(x: position, y: rulerHeight))
                    },
                    with: .color(Theme.hairline),
                    lineWidth: 1
                )
                let label = Timecode.string(
                    fromSeconds: tick,
                    rate: state.project.frameRate,
                    dropFrame: state.project.dropFrame
                )
                context.draw(
                    Text(label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary),
                    at: CGPoint(x: position + 3, y: 8),
                    anchor: .leading
                )
            }
            tick += step
        }
    }

    /// Picks a ruler interval that leaves the labels readable at any zoom.
    private func tickStep(for visible: Double) -> Double {
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let target = visible / 8
        return candidates.first { $0 >= target } ?? 3600
    }

    private func drawClipLane(context: GraphicsContext, width: CGFloat) {
        let top = rulerHeight + 2
        let height = clipLaneHeight - 4

        for clip in state.project.clips {
            let startX = x(for: clip.start, width: width)
            let endX = x(for: clip.end, width: width)
            guard endX > 0, startX < width else { continue }

            let rect = CGRect(x: startX, y: top, width: max(endX - startX, 2), height: height)
            let isSelected = clip.id == state.selectedClipID
            let path = Path(roundedRect: rect, cornerRadius: 3)

            // Segments alternate, so the lane is painted in bands: muted for
            // a before stretch, saturated for an after one.
            context.fill(
                path,
                with: .color(Theme.clipTint.opacity(clip.isEnabled ? 0.28 : 0.10))
            )

            let bounds = [clip.start] + clip.switches + [clip.end]
            for index in 0..<(bounds.count - 1) where !index.isMultiple(of: 2) {
                let from = max(x(for: bounds[index], width: width), rect.minX)
                let to = min(x(for: bounds[index + 1], width: width), rect.maxX)
                guard to > from else { continue }
                context.fill(
                    Path(CGRect(x: from, y: top, width: to - from, height: height)),
                    with: .color(Theme.afterTint.opacity(clip.isEnabled ? 0.30 : 0.10))
                )
            }

            for point in clip.switches {
                let markX = x(for: point, width: width)
                guard markX > rect.minX, markX < rect.maxX else { continue }
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: markX, y: top))
                        path.addLine(to: CGPoint(x: markX, y: top + height))
                    },
                    with: .color(.white.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            }

            context.stroke(
                path,
                with: .color(isSelected ? Theme.clipTint : Theme.hairline),
                lineWidth: isSelected ? 2 : 1
            )

            if rect.width > 46 {
                context.draw(
                    Text(clip.name)
                        .font(.system(size: 9, weight: .medium)),
                    at: CGPoint(x: rect.minX + 5, y: top + height / 2),
                    anchor: .leading
                )
            }
        }
    }

    private func drawLane(context: GraphicsContext, source: AudioSource, width: CGFloat, top: CGFloat) {
        let height = laneHeight - 6
        let startX = x(for: source.offsetSeconds, width: width)
        let endX = x(for: source.offsetSeconds + source.durationSeconds, width: width)
        let rect = CGRect(x: startX, y: top + 3, width: max(endX - startX, 2), height: height)

        let tint: Color
        if source.id == state.project.defaultBeforeSourceID {
            tint = Theme.beforeTint
        } else if source.id == state.project.defaultAfterSourceID {
            tint = Theme.afterTint
        } else {
            tint = .secondary
        }

        context.fill(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(tint.opacity(source.isEnabled ? 0.16 : 0.06))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(tint.opacity(0.5)),
            lineWidth: 1
        )

        if let peaks = state.waveforms[source.id], !peaks.isEmpty, rect.width > 4 {
            drawWaveform(
                context: context,
                peaks: peaks,
                rect: rect.insetBy(dx: 1, dy: 3),
                tint: tint.opacity(source.isEnabled ? 0.85 : 0.3)
            )
        }

        context.draw(
            Text(source.name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary),
            at: CGPoint(x: max(rect.minX, 0) + 4, y: top + 9),
            anchor: .leading
        )
    }

    private func drawWaveform(context: GraphicsContext, peaks: [Float], rect: CGRect, tint: Color) {
        let midline = rect.midY
        let columns = Int(rect.width)
        guard columns > 0 else { return }

        var path = Path()
        for column in 0..<columns {
            // The envelope is stored per file, so it is sampled here rather
            // than resampled — the lane may be wider or narrower than 900 px.
            let fraction = Double(column) / Double(columns)
            let index = min(peaks.count - 1, Int(fraction * Double(peaks.count)))
            let magnitude = CGFloat(min(max(peaks[index], 0), 1))
            let half = magnitude * rect.height / 2
            guard half > 0.2 else { continue }
            let x = rect.minX + CGFloat(column)
            path.move(to: CGPoint(x: x, y: midline - half))
            path.addLine(to: CGPoint(x: x, y: midline + half))
        }
        context.stroke(path, with: .color(tint), lineWidth: 1)
    }

    // MARK: - Interaction

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard value.location.y < rulerHeight else { return }
                player.seek(to: seconds(forX: value.location.x, width: width))
            }
    }

    /// Works out what a drag grabbed: an edge, the split marker, or the body.
    private func beginClipDrag(atX x: CGFloat, width: CGFloat) -> ClipDrag? {
        let time = seconds(forX: x, width: width)
        // Eight points of slop, expressed in seconds at the current zoom.
        let slop = Double(8 / max(width, 1)) * visibleDuration

        // Later clips are drawn on top, so they win a hit test.
        for clip in state.project.clips.reversed() {
            guard time >= clip.start - slop, time <= clip.end + slop else { continue }

            let nearestSwitch = clip.switches.min {
                abs($0 - time) < abs($1 - time)
            }

            let handle: ClipDrag.Handle
            if abs(time - clip.start) <= slop {
                handle = .trimIn
            } else if abs(time - clip.end) <= slop {
                handle = .trimOut
            } else if let nearestSwitch, abs(time - nearestSwitch) <= slop {
                handle = .split
            } else {
                handle = .move
            }

            return ClipDrag(
                clipID: clip.id,
                handle: handle,
                originStart: clip.start,
                originEnd: clip.end,
                originSplit: nearestSwitch ?? clip.splitTime
            )
        }
        return nil
    }

    private func applyClipDrag(_ drag: ClipDrag, delta: Double) {
        // With a fixed house length an edge drag slides the window rather than
        // trimming it, matching what Mark in / Mark out do.
        let locked = state.project.keepClipLengthFixed

        switch drag.handle {
        case .move:
            state.moveClip(drag.clipID, toStart: drag.originStart + delta)
        case .trimIn:
            if locked {
                state.moveClip(drag.clipID, toStart: drag.originStart + delta)
            } else {
                state.trimClip(drag.clipID, start: drag.originStart + delta, end: drag.originEnd)
            }
        case .trimOut:
            if locked {
                state.moveClip(drag.clipID, toStart: drag.originStart + delta)
            } else {
                state.trimClip(drag.clipID, start: drag.originStart, end: drag.originEnd + delta)
            }
        case .split:
            state.moveSwitch(drag.clipID, from: drag.originSplit, to: drag.originSplit + delta)
        }
    }

    /// The clip lane: drag a body to move it, an edge to trim, the dashed mark
    /// to move the A/B switch. Empty space scrubs.
    private func clipLaneStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(height: clipLaneHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if clipDrag == nil {
                            clipDrag = beginClipDrag(atX: value.startLocation.x, width: width)
                            if let clipDrag {
                                state.focusClip(clipDrag.clipID)
                            }
                        }
                        guard let clipDrag else {
                            player.seek(to: seconds(forX: value.location.x, width: width))
                            return
                        }
                        let delta = Double(value.translation.width / max(width, 1)) * visibleDuration
                        applyClipDrag(clipDrag, delta: delta)
                    }
                    .onEnded { _ in
                        if clipDrag != nil {
                            clipDrag = nil
                            // One rebuild at the end rather than one per pixel.
                            state.applyPlayerSettings()
                        }
                    }
            )
    }

    /// One invisible strip per audio lane that turns a horizontal drag into a
    /// sync offset.
    private func laneDragOverlay(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: rulerHeight)
            clipLaneStrip(width: width)
            ForEach(visibleSources) { source in
                LaneDragStrip(
                    height: laneHeight,
                    isDraggable: !source.isEmbedded,
                    onDrag: { translation in
                        let delta = Double(translation / max(width, 1)) * visibleDuration
                        state.shiftOffset(delta, forSourceID: source.id)
                    }
                )
            }
        }
        .allowsHitTesting(true)
    }

    private func playheadOverlay(width: CGFloat) -> some View {
        let position = x(for: player.currentTime, width: width)
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: totalHeight)
            .offset(x: position)
            .opacity(position >= 0 && position <= width ? 1 : 0)
            .allowsHitTesting(false)
    }
}

/// A drag target for one audio lane. Kept separate so each lane can hold its
/// own gesture state without the parent redrawing on every pixel.
@MainActor
private struct LaneDragStrip: View {
    let height: CGFloat
    let isDraggable: Bool
    let onDrag: (CGFloat) -> Void

    @State private var lastTranslation: CGFloat = 0

    var body: some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let delta = value.translation.width - lastTranslation
                        lastTranslation = value.translation.width
                        onDrag(delta)
                    }
                    .onEnded { _ in lastTranslation = 0 },
                including: isDraggable ? .gesture : .subviews
            )
    }
}
