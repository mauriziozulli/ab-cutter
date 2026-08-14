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
            Text("Load a finished film, then lay your mixes under it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose video…") { state.presentVideoPicker() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Monitoring

    private var monitorBar: some View {
        HStack(spacing: 12) {
            Text("Monitor")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Picker("", selection: monitorSelection) {
                Text("A/B follow split").tag(MonitorSelection.followSplit)
                ForEach(state.project.audioSources) { source in
                    Text(source.name).tag(MonitorSelection.single(source.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Divider().frame(height: 16)

            Text("Framing")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)

            Picker("", selection: previewFormatBinding) {
                Text("Full frame").tag(SocialFormat?.none)
                ForEach(SocialFormat.allCases) { format in
                    Text(format.title).tag(SocialFormat?.some(format))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Toggle("Loop in clip", isOn: limitBinding)
                .toggleStyle(.checkbox)
                .font(.caption)

            Spacer()
        }
        .padding(.horizontal, Theme.panelPadding)
        .padding(.vertical, 6)
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
            .help("Back 10 frames")

            Button { player.step(frames: -1, frameRate: state.project.frameRate) } label: {
                Image(systemName: "backward.frame")
            }
            .help("Back one frame")

            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / pause")

            Button { player.step(frames: 1, frameRate: state.project.frameRate) } label: {
                Image(systemName: "forward.frame")
            }
            .help("Forward one frame")

            Button { player.step(frames: 10, frameRate: state.project.frameRate) } label: {
                Image(systemName: "forward.end.alt")
            }
            .help("Forward 10 frames")

            Divider().frame(height: 16)

            Text(positionLabel)
                .timecodeStyle(size: 12)

            if let clip {
                Text(halfLabel(for: clip))
                    .font(.caption)
                    .foregroundStyle(player.currentTime < clip.splitTime ? Theme.beforeTint : Theme.afterTint)
            }

            Spacer()

            Button("Mark in") { state.markIn() }
                .disabled(clip == nil)
                .help(state.project.keepClipLengthFixed
                      ? "Start the fixed-length window here"
                      : "Trim the head to the playhead")
            Button("Mark out") { state.markOut() }
                .disabled(clip == nil)
                .help(state.project.keepClipLengthFixed
                      ? "End the fixed-length window here"
                      : "Trim the tail to the playhead")
            Button("Split here") { state.setSplitToPlayhead() }
                .disabled(clip == nil)
            Button("New clip") { state.addClipAtPlayhead() }
                .disabled(!state.project.hasVideo)
                .keyboardShortcut("n", modifiers: .command)
                .help("Drop a \(String(format: "%g", state.project.defaultClipLengthSeconds)) s clip at the playhead (⌘N)")
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
        guard player.currentTime >= clip.start, player.currentTime <= clip.end else { return "outside clip" }
        return player.currentTime < clip.splitTime ? "BEFORE half" : "AFTER half"
    }
}
