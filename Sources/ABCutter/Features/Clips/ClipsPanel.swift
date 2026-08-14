import SwiftUI

/// Right column, upper half: the clip list and the inspector for the selected
/// clip — in, out, where the A/B switch falls, and how it is framed.
@MainActor
struct ClipsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            clipList
            if let clip = state.selectedClip {
                ClipInspector(state: state, clip: clip)
            } else {
                Text("Select a clip to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(state.project.clips) { clip in
                clipRow(clip)
            }

            if state.project.clips.isEmpty {
                Text("No clips yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Add clip at playhead") { state.addClipAtPlayhead() }
                .controlSize(.small)
                .disabled(!state.project.hasVideo)
        }
        .abSection("Clips")
    }

    private func clipRow(_ clip: Clip) -> some View {
        let isSelected = clip.id == state.selectedClipID
        return HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { clip.isEnabled },
                set: { newValue in
                    var updated = clip
                    updated.isEnabled = newValue
                    state.updateClip(updated)
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Include in a batch export")

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(Timecode.clockString(fromSeconds: clip.start)) → \(Timecode.clockString(fromSeconds: clip.end))  ·  \(String(format: "%.1f s", clip.duration))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                state.removeClip(clip)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.clipTint.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { state.selectClip(clip) }
    }
}

/// Everything about one clip that the export reads.
@MainActor
struct ClipInspector: View {
    @ObservedObject var state: AppState
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: Binding(
                get: { clip.name },
                set: { newValue in
                    var updated = clip
                    updated.name = newValue
                    state.updateClip(updated)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            timeRow(
                label: "In",
                seconds: clip.start,
                onSet: { value in
                    var updated = clip
                    updated.start = min(value, clip.end - state.project.frameDuration)
                    state.updateClip(updated)
                },
                onMark: { state.markIn() }
            )

            timeRow(
                label: "Out",
                seconds: clip.end,
                onSet: { value in
                    var updated = clip
                    updated.end = max(value, clip.start + state.project.frameDuration)
                    state.updateClip(updated)
                },
                onMark: { state.markOut() }
            )

            splitRow

            Divider()

            abRow(
                title: "Before",
                tint: Theme.beforeTint,
                selection: Binding(
                    get: { clip.beforeSourceID },
                    set: { newValue in
                        var updated = clip
                        updated.beforeSourceID = newValue
                        state.updateClip(updated)
                    }
                ),
                resolved: state.project.beforeSource(for: clip)
            )

            abRow(
                title: "After",
                tint: Theme.afterTint,
                selection: Binding(
                    get: { clip.afterSourceID },
                    set: { newValue in
                        var updated = clip
                        updated.afterSourceID = newValue
                        state.updateClip(updated)
                    }
                ),
                resolved: state.project.afterSource(for: clip)
            )

            Divider()
            framingControls
        }
        .abCard()
        .abSection("Clip")
    }

    private func timeRow(
        label: String,
        seconds: Double,
        onSet: @escaping (Double) -> Void,
        onMark: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 34, alignment: .leading)
            Text(Timecode.string(
                fromSeconds: seconds,
                rate: state.project.frameRate,
                dropFrame: state.project.dropFrame
            ))
            .timecodeStyle(size: 11)
            Spacer()
            Button("Set") { onMark() }
                .controlSize(.mini)
                .help("Use the current playhead position")
            Button {
                state.player.seek(to: seconds)
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .controlSize(.mini)
            .help("Jump the playhead here")
        }
        .buttonStyle(.bordered)
    }

    private var splitRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Split")
                    .font(.caption)
                    .frame(width: 34, alignment: .leading)
                Text(Timecode.string(
                    fromSeconds: clip.splitTime,
                    rate: state.project.frameRate,
                    dropFrame: state.project.dropFrame
                ))
                .timecodeStyle(size: 11)
                if clip.splitOverride == nil {
                    Text("middle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Set") { state.setSplitToPlayhead() }
                    .controlSize(.mini)
                Button("Middle") { state.resetSplitToMiddle() }
                    .controlSize(.mini)
                    .disabled(clip.splitOverride == nil)
            }
            .buttonStyle(.bordered)

            Slider(
                value: Binding(
                    get: { clip.splitFraction },
                    set: { fraction in
                        var updated = clip
                        updated.splitOverride = clip.start + fraction * clip.duration
                        state.updateClip(updated)
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
        }
    }

    private func abRow(
        title: String,
        tint: Color,
        selection: Binding<UUID?>,
        resolved: AudioSource?
    ) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .frame(width: 44, alignment: .leading)
            Picker("", selection: selection) {
                Text(defaultLabel(resolved)).tag(UUID?.none)
                ForEach(state.project.audioSources) { source in
                    Text(source.name).tag(UUID?.some(source.id))
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func defaultLabel(_ resolved: AudioSource?) -> String {
        guard let resolved else { return "Default (—)" }
        return "Default (\(resolved.name))"
    }

    private var framingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Framing inside the crop")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("↔")
                    .font(.caption)
                    .frame(width: 14)
                Slider(
                    value: Binding(
                        get: { clip.panX },
                        set: { newValue in
                            var updated = clip
                            updated.panX = newValue
                            state.updateClip(updated)
                        }
                    ),
                    in: -1...1
                )
                .controlSize(.mini)
                Button("0") {
                    var updated = clip
                    updated.panX = 0
                    state.updateClip(updated)
                }
                .controlSize(.mini)
            }

            HStack(spacing: 6) {
                Text("↕")
                    .font(.caption)
                    .frame(width: 14)
                Slider(
                    value: Binding(
                        get: { clip.panY },
                        set: { newValue in
                            var updated = clip
                            updated.panY = newValue
                            state.updateClip(updated)
                        }
                    ),
                    in: -1...1
                )
                .controlSize(.mini)
                Button("0") {
                    var updated = clip
                    updated.panY = 0
                    state.updateClip(updated)
                }
                .controlSize(.mini)
            }

            Text("Only applies when the format crops — pick a framing preview above to see it.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
