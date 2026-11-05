import AppKit
import SwiftUI

/// The session laid out flat: a ruler with In/Out, the takes, the A/B lane, the
/// stills lane, and both mixes as waveforms.
///
/// Switches and stills are flags that hang in their own lanes and slide by
/// drag — the picture follows the hand. A click on empty space places the
/// playhead. The stretch outside In/Out is shaded: it stays in the session
/// but not in the export.
@MainActor
struct TimelineView: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style

    private let rulerHeight: CGFloat = 24
    private let takeLaneHeight: CGFloat = 16
    private let switchLaneHeight: CGFloat = 30
    private let stillLaneHeight: CGFloat = 24
    private let waveLaneHeight: CGFloat = 44

    private struct Drag {
        var target: MarkerSelection
        var origin: Double
        var moved = false
    }

    private enum Edge { case inPoint, outPoint }

    private struct EdgeDrag {
        var edge: Edge
        var origin: Double
    }

    @State private var drag: Drag?
    @State private var edgeDrag: EdgeDrag?
    @State private var scrubbing = false

    private var duration: Double { max(store.session.duration, 0.1) }

    private var visible: Double { max(duration / max(store.zoom, 1), 0.5) }

    private var windowStart: Double {
        guard visible < duration else { return 0 }
        return min(max(store.currentTime - visible / 2, 0), duration - visible)
    }

    private var totalHeight: CGFloat {
        rulerHeight + takeLaneHeight + switchLaneHeight + stillLaneHeight + waveLaneHeight * 2
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            StudioHairline(soft: true)
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in draw(context, width: size.width) }
                    VStack(spacing: 0) {
                        rulerStrip(width: width)
                        scrubStrip(width: width, height: takeLaneHeight)
                        markerStrip(width: width, height: switchLaneHeight, lane: .switches)
                        markerStrip(width: width, height: stillLaneHeight, lane: .stills)
                        scrubStrip(width: width, height: waveLaneHeight * 2)
                    }
                    Rectangle()
                        .fill(style.error)
                        .frame(width: 1.5, height: totalHeight)
                        .offset(x: x(store.currentTime, width: width))
                        .allowsHitTesting(false)
                }
            }
            .frame(height: totalHeight)
            .background(style.bg)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { store.addSwitchAtPlayhead() } label: { Label("Wechsel", systemImage: "plus") }
                .help("A/B-Wechsel am Abspielkopf (⌘\\ oder W)")
            Button { store.addStillAtPlayhead() } label: { Label("Still", systemImage: "plus") }
                .help("Still am Abspielkopf (⇧⌘M oder S)")
            Button("Löschen") { store.deleteSelection() }
                .disabled(store.selection == nil)
                .help("Gewählten Marker entfernen (⌫)")

            Rectangle().fill(style.line).frame(width: 1, height: 16)

            Button("In") { store.markIn() }
                .help("Exportbeginn am Abspielkopf (I)")
            Button("Out") { store.markOut() }
                .help("Exportende am Abspielkopf (O)")

            Text("\(Clock.string(store.session.exportRange.lowerBound)) – \(Clock.string(store.session.exportRange.upperBound))")
                .font(style.mono(AppType.small))
                .foregroundStyle(style.faint)

            Spacer()

            Image(systemName: "minus.magnifyingglass").foregroundStyle(style.faint)
            Slider(value: $store.zoom, in: 1...60).controlSize(.mini).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(style.faint)
        }
        .buttonStyle(StudioButtonStyle())
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: style.barHeight + 6)
        .background(style.panel)
    }

    // MARK: - Mapping

    private func x(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat((seconds - windowStart) / visible) * width
    }

    private func seconds(_ x: CGFloat, width: CGFloat) -> Double {
        windowStart + Double(x / max(width, 1)) * visible
    }

    // MARK: - Drawing

    private func draw(_ context: GraphicsContext, width: CGFloat) {
        drawRuler(context, width: width)

        let takeTop = rulerHeight
        let switchTop = takeTop + takeLaneHeight
        let stillTop = switchTop + switchLaneHeight
        let waveTop = stillTop + stillLaneHeight
        let session = store.session

        // A/B bands.
        let bounds: [Double] = [0.0] + session.sortedSwitches + [duration]
        for index in 0..<(bounds.count - 1) {
            let from = x(bounds[index], width: width)
            let to = x(bounds[index + 1], width: width)
            guard to > 0, from < width else { continue }
            let isMix = index % 2 == 1
            let rect = CGRect(x: from, y: switchTop + 4, width: max(to - from, 1), height: switchLaneHeight - 8)
            context.fill(Path(rect), with: .color((isMix ? Tint.mix : Tint.original).opacity(0.35)))
            if rect.width > 70 {
                context.draw(
                    Text(isMix ? session.labelMix : session.labelOriginal)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85)),
                    at: CGPoint(x: max(rect.minX, 0) + 6, y: rect.midY),
                    anchor: .leading
                )
            }
        }

        // Switch flags.
        for (index, point) in session.switches.enumerated() {
            let position = x(point, width: width)
            guard position > -10, position < width + 10 else { continue }
            let selected = store.selection == .switchPoint(index)
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: position, y: switchTop))
                    path.addLine(to: CGPoint(x: position, y: totalHeight))
                },
                with: .color(.white.opacity(selected ? 0.9 : 0.4)),
                lineWidth: selected ? 1.5 : 1
            )
            let flag = CGRect(x: position - 6, y: switchTop + 2, width: 12, height: switchLaneHeight - 4)
            context.fill(Path(roundedRect: flag, cornerRadius: 3), with: .color(selected ? .white : .white.opacity(0.7)))
        }

        // Still flags.
        for (index, still) in session.sortedStills.enumerated() {
            let position = x(still.time, width: width)
            guard position > -10, position < width + 10 else { continue }
            let selected = store.selection == .still(still.id)
            let flag = CGRect(x: position - 9, y: stillTop + 3, width: 18, height: stillLaneHeight - 6)
            context.fill(Path(roundedRect: flag, cornerRadius: 4), with: .color(Tint.still.opacity(selected ? 1 : 0.6)))
            if selected {
                context.stroke(Path(roundedRect: flag, cornerRadius: 4), with: .color(.white), lineWidth: 1.5)
            }
            context.draw(
                Text("\(index + 1)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundColor(.black),
                at: CGPoint(x: flag.midX, y: flag.midY)
            )
        }

        // Takes, and under them each take's two mixes where it plays.
        let segments = session.segments()
        let numbers = Dictionary(uniqueKeysWithValues: session.takes.enumerated().map { ($1.id, $0 + 1) })
        for segment in segments {
            let from = x(segment.from, width: width)
            let to = x(segment.to, width: width)
            guard to > 0, from < width else { continue }
            let rect = CGRect(x: from, y: takeTop + 2, width: max(to - from, 1), height: takeLaneHeight - 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(style.raised))
            if rect.width > 40 {
                context.draw(
                    Text("Take \(numbers[segment.take.id] ?? 0)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(style.muted),
                    at: CGPoint(x: max(rect.minX, 0) + 5, y: rect.midY),
                    anchor: .leading
                )
            }
            let waves = store.waveforms[segment.take.id]
            drawWave(context, waves?.original ?? nil, segment: segment, lead: segment.take.originalLead,
                     top: waveTop, tint: Tint.original, width: width)
            drawWave(context, waves?.mix ?? nil, segment: segment, lead: segment.take.mixLead,
                     top: waveTop + waveLaneHeight, tint: Tint.mix, width: width)
        }

        // Outside In/Out.
        let range = session.exportRange
        let shade = Color.black.opacity(0.45)
        let inX = x(range.lowerBound, width: width)
        let outX = x(range.upperBound, width: width)
        if inX > 0 {
            context.fill(Path(CGRect(x: 0, y: rulerHeight, width: inX, height: totalHeight)), with: .color(shade))
        }
        if outX < width {
            context.fill(Path(CGRect(x: outX, y: rulerHeight, width: width - outX, height: totalHeight)), with: .color(shade))
        }

        // In and Out as handles on the ruler, to be dragged like an editor's.
        let accent = style.ready
        if inX >= -8, inX <= width + 8 {
            var bracket = Path()
            bracket.move(to: CGPoint(x: inX + 7, y: 2))
            bracket.addLine(to: CGPoint(x: inX, y: 2))
            bracket.addLine(to: CGPoint(x: inX, y: rulerHeight))
            bracket.addLine(to: CGPoint(x: inX + 7, y: rulerHeight))
            context.stroke(bracket, with: .color(accent), lineWidth: 2.5)
        }
        if outX >= -8, outX <= width + 8 {
            var bracket = Path()
            bracket.move(to: CGPoint(x: outX - 7, y: 2))
            bracket.addLine(to: CGPoint(x: outX, y: 2))
            bracket.addLine(to: CGPoint(x: outX, y: rulerHeight))
            bracket.addLine(to: CGPoint(x: outX - 7, y: rulerHeight))
            context.stroke(bracket, with: .color(accent), lineWidth: 2.5)
        }
    }

    private func drawRuler(_ context: GraphicsContext, width: CGFloat) {
        let candidates: [Double] = [0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = candidates.first { $0 >= visible / 8 } ?? 600
        var tick = (windowStart / step).rounded(.down) * step
        while tick <= windowStart + visible {
            let position = x(tick, width: width)
            if position >= 0, position <= width {
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: position, y: rulerHeight - 6))
                        path.addLine(to: CGPoint(x: position, y: rulerHeight))
                    },
                    with: .color(style.line),
                    lineWidth: 1
                )
                context.draw(
                    Text(Clock.string(tick)).font(.system(size: 9).monospacedDigit()).foregroundColor(style.faint),
                    at: CGPoint(x: position + 3, y: 8),
                    anchor: .leading
                )
            }
            tick += step
        }
    }

    private func drawWave(
        _ context: GraphicsContext,
        _ waveform: Waveform?,
        segment: TakeSegment,
        lead: Double,
        top: CGFloat,
        tint: Color,
        width: CGFloat
    ) {
        let mid = top + waveLaneHeight / 2
        let half = waveLaneHeight / 2 - 4
        let first = max(Int(x(segment.from, width: width).rounded(.down)), 0)
        let last = min(Int(x(segment.to, width: width).rounded(.up)), Int(width))
        guard last > first else { return }
        guard let waveform else {
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: CGFloat(first), y: mid))
                    path.addLine(to: CGPoint(x: CGFloat(last), y: mid))
                },
                with: .color(tint.opacity(0.3)),
                lineWidth: 1
            )
            return
        }
        // File time = timeline time − take start − lead.
        let shift = segment.take.start + lead
        var path = Path()
        for column in first..<last {
            let start = seconds(CGFloat(column), width: width) - shift
            let end = seconds(CGFloat(column + 1), width: width) - shift
            let height = CGFloat(min(max(waveform.peak(from: start, to: end), 0), 1)) * half
            guard height > 0.3 else { continue }
            path.move(to: CGPoint(x: CGFloat(column), y: mid - height))
            path.addLine(to: CGPoint(x: CGFloat(column), y: mid + height))
        }
        context.stroke(path, with: .color(tint.opacity(0.8)), lineWidth: 1)
    }

    // MARK: - Interaction

    private enum Lane { case switches, stills }

    private static func releaseKeyboard() {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func scrubStrip(width: CGFloat, height: CGFloat) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    Self.releaseKeyboard()
                    store.seek(to: seconds(value.location.x, width: width))
                }
            )
    }

    /// The ruler: grab an In or Out bracket to move it, anywhere else scrubs.
    private func rulerStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(height: rulerHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if edgeDrag == nil, !scrubbing {
                            Self.releaseKeyboard()
                            let range = store.session.exportRange
                            let inX = x(range.lowerBound, width: width)
                            let outX = x(range.upperBound, width: width)
                            let start = value.startLocation.x
                            if abs(start - inX) <= 9, abs(start - inX) <= abs(start - outX) {
                                edgeDrag = EdgeDrag(edge: .inPoint, origin: range.lowerBound)
                            } else if abs(start - outX) <= 9 {
                                edgeDrag = EdgeDrag(edge: .outPoint, origin: range.upperBound)
                            } else {
                                scrubbing = true
                            }
                        }
                        if let edge = edgeDrag {
                            let time = edge.origin + Double(value.translation.width / width) * visible
                            switch edge.edge {
                            case .inPoint: store.setIn(time)
                            case .outPoint: store.setOut(time)
                            }
                        } else {
                            store.seek(to: seconds(value.location.x, width: width))
                        }
                    }
                    .onEnded { _ in
                        edgeDrag = nil
                        scrubbing = false
                    }
            )
    }

    private func markerStrip(width: CGFloat, height: CGFloat, lane: Lane) -> some View {
        Color.clear
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            Self.releaseKeyboard()
                            drag = hit(lane: lane, x: value.startLocation.x, width: width)
                            if let drag {
                                store.selection = drag.target
                                store.beginDrag()
                            } else {
                                store.selection = nil
                            }
                        }
                        guard let current = drag else {
                            store.seek(to: seconds(value.location.x, width: width))
                            return
                        }
                        if abs(value.translation.width) > 3 { drag?.moved = true }
                        guard drag?.moved == true else { return }
                        let time = current.origin + Double(value.translation.width / width) * visible
                        switch current.target {
                        case .switchPoint(let index): store.moveSwitch(index, to: time)
                        case .still(let id): store.moveStill(id, to: time)
                        }
                        store.seek(to: time)
                    }
                    .onEnded { _ in
                        guard let finished = drag else { return }
                        drag = nil
                        store.endDrag()
                        if !finished.moved { store.seek(to: finished.origin) }
                    }
            )
    }

    private func hit(lane: Lane, x position: CGFloat, width: CGFloat) -> Drag? {
        let slop = Double(10 / width) * visible
        let time = seconds(position, width: width)
        switch lane {
        case .switches:
            let candidates = store.session.switches.enumerated().filter { abs($0.element - time) <= slop }
            guard let best = candidates.min(by: { abs($0.element - time) < abs($1.element - time) }) else { return nil }
            return Drag(target: .switchPoint(best.offset), origin: best.element)
        case .stills:
            let candidates = store.session.stills.filter { abs($0.time - time) <= slop }
            guard let best = candidates.min(by: { abs($0.time - time) < abs($1.time - time) }) else { return nil }
            return Drag(target: .still(best.id), origin: best.time)
        }
    }
}
