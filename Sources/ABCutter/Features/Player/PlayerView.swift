import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// A plain AVPlayerLayer host — the app draws its own transport, so AVKit's
/// stock controls would only get in the way.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// The centre column: picture, transport, and the A/B monitoring switches.
@MainActor
struct PlayerPane: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: PlayerController

    private var clip: Clip? { state.selectedClip }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if state.project.hasVideo {
                    PlayerSurface(player: player.player)
                        .overlay {
                            // The guides belong to the whole picture; a format
                            // preview or clip preview already shows one real
                            // crop, so they would only lie there.
                            if state.showFormatGuides,
                               player.previewFormat == nil,
                               !player.isClipPreview {
                                FormatGuidesOverlay(
                                    project: state.project,
                                    clip: state.selectedClip
                                )
                            }
                        }
                } else {
                    emptyState
                }
                if player.isPreparing {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            monitorBar
            Divider()
            transportBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Fertigen Film laden, dann die Mixe darunterlegen.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Video wählen …") { state.presentVideoPicker() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Monitoring

    private var monitorBar: some View {
        HStack(spacing: 12) {
            Text("Abhöre")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Picker("", selection: monitorSelection) {
                Text("A/B folgt Wechseln").tag(MonitorSelection.followSplit)
                ForEach(state.project.audioSources) { source in
                    Text(source.name).tag(MonitorSelection.single(source.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Divider().frame(height: 16)

            Text("Format")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Picker("", selection: previewFormatBinding) {
                Text("Ganzes Bild").tag(SocialFormat?.none)
                ForEach(SocialFormat.allCases) { format in
                    Text(format.title).tag(SocialFormat?.some(format))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Toggle("Ausschnitte", isOn: $state.showFormatGuides)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(player.previewFormat != nil || player.isClipPreview)
                .help("Zeichnet im ganzen Bild farbige Umrisse: was jedes gewählte Ausgabeformat vom Film behält")

            Divider().frame(height: 16)

            // A straight comparison, independent of where the switches fall.
            // This is what an ear wants when checking two mixes against each
            // other, and it also shows at once whether both are audible at all.
            Button("Nur A") { state.monitorOnlySide(before: true) }
                .controlSize(.small)
                .tint(isSoloing(before: true) ? Theme.beforeTint : nil)
                .disabled(state.project.audioSources.isEmpty)
            Button("Nur B") { state.monitorOnlySide(before: false) }
                .controlSize(.small)
                .tint(isSoloing(before: false) ? Theme.afterTint : nil)
                .disabled(state.project.audioSources.isEmpty)

            Toggle("Im Clip bleiben", isOn: limitBinding)
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(player.isClipPreview)

            Divider().frame(height: 16)

            // The export, played: clip composition, mix, look — and for a
            // loop both passes, which the raw timeline cannot show at all.
            Toggle("Clip-Vorschau", isOn: Binding(
                get: { player.isClipPreview },
                set: { _ in state.toggleClipPreview() }
            ))
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(state.selectedClip.map { Theme.tint(for: $0.kind) })
            .disabled(state.selectedClip == nil)
            .help("Spielt den gewählten Clip genau so, wie er exportiert wird — beim Loop mit beiden Durchläufen")

            Spacer()
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 6)
    }

    private func isSoloing(before: Bool) -> Bool {
        guard case .single(let id) = player.monitorMode else { return false }
        return id == state.resolvedSideID(before: before)
    }

    private enum MonitorSelection: Hashable {
        case followSplit
        case single(UUID)
    }

    private var monitorSelection: Binding<MonitorSelection> {
        Binding(
            get: {
                switch player.monitorMode {
                case .followSplit: .followSplit
                case .single(let id): .single(id)
                }
            },
            set: { selection in
                switch selection {
                case .followSplit: player.monitorMode = .followSplit
                case .single(let id): player.monitorMode = .single(id)
                }
                state.applyPlayerSettings()
            }
        )
    }

    private var previewFormatBinding: Binding<SocialFormat?> {
        Binding(
            get: { player.previewFormat },
            set: {
                player.previewFormat = $0
                state.applyPlayerSettings()
            }
        )
    }

    private var limitBinding: Binding<Bool> {
        Binding(
            get: { player.limitToClip },
            set: {
                player.limitToClip = $0
                state.applyPlayerSettings()
            }
        )
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 10) {
            Button { player.step(frames: -10, frameRate: state.project.frameRate) } label: {
                Image(systemName: "backward.end.alt")
            }
            .help("10 Bilder zurück")

            Button { player.step(frames: -1, frameRate: state.project.frameRate) } label: {
                Image(systemName: "backward.frame")
            }
            .help("Ein Bild zurück")

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Abspielen / Pause")

            Button { player.step(frames: 1, frameRate: state.project.frameRate) } label: {
                Image(systemName: "forward.frame")
            }
            .help("Ein Bild vor")

            Button { player.step(frames: 10, frameRate: state.project.frameRate) } label: {
                Image(systemName: "forward.end.alt")
            }
            .help("10 Bilder vor")

            Divider().frame(height: 16)

            Text(positionLabel)
                .timecodeStyle(size: 12)

            if let clip {
                Text(halfLabel(for: clip))
                    .font(.caption)
                    .foregroundStyle(clip.isBeforeSegment(at: player.currentTime) ? Theme.beforeTint : Theme.afterTint)
            }

            Spacer()

            Button("In") { state.markIn() }
                .disabled(clip == nil)
                .help("Anfang auf den Abspielkopf trimmen — der A/B-Wechsel bleibt, wo er ist")
            Button("Out") { state.markOut() }
                .disabled(clip == nil)
                .help("Ende auf den Abspielkopf trimmen — der A/B-Wechsel bleibt, wo er ist")
            Button("Wechsel +") { state.addSwitchAtPlayhead() }
                .disabled(clip == nil)
            Button("Neuer Clip") { state.addClipAtPlayhead() }
                .disabled(!state.project.hasVideo)
                .help("Setzt einen \(String(format: "%g", state.project.defaultClipLengthSeconds))-s-Clip am Abspielkopf (⌘N)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 8)
    }

    private var positionLabel: String {
        let project = state.project
        let elapsed = Timecode.string(
            fromSeconds: player.currentTime,
            rate: project.frameRate,
            dropFrame: project.dropFrame
        )
        guard let start = project.videoTimecodeStartSeconds else { return elapsed }
        let absolute = Timecode.string(
            fromSeconds: start + player.currentTime,
            rate: project.frameRate,
            dropFrame: project.dropFrame
        )
        return "\(elapsed)   TC \(absolute)"
    }

    private func halfLabel(for clip: Clip) -> String {
        guard player.currentTime >= clip.start, player.currentTime <= clip.end else { return "ausserhalb des Clips" }
        return clip.isBeforeSegment(at: player.currentTime) ? "Hört A" : "Hört B"
    }
}
