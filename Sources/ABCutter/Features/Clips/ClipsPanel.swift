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
                // The look lives on the clip, so it is edited right here —
                // selecting a clip *is* opening its settings.
                ClipLookPanel(state: state)
            } else {
                Text("Einen Clip wählen, um ihn zu bearbeiten.")
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
                Text("Noch keine Clips.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Button("Neuer A/B-Clip") { state.addClipAtPlayhead(kind: .ab) }
                    .controlSize(.small)
                    .tint(Theme.clipTint)
                Button("Neuer Loop") { state.addClipAtPlayhead(kind: .loop) }
                    .controlSize(.small)
                    .tint(Theme.loopTint)
                Spacer()
                Text("\(String(format: "%g", state.project.defaultClipLengthSeconds)) s am Abspielkopf")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
            .help("Beim Stapelexport berücksichtigen")

            Circle()
                .fill(Theme.tint(for: clip.kind))
                .frame(width: 7, height: 7)
                .help(clip.kind.title)

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.kind == .loop ? "\u{21bb} \(clip.name)" : clip.name)
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
                .fill(isSelected ? Theme.tint(for: clip.kind).opacity(0.18) : Color.clear)
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

            Picker("Typ", selection: Binding(
                get: { clip.kind },
                set: { newValue in
                    var updated = clip
                    updated.kind = newValue
                    state.updateClip(updated)
                    state.refreshPreviewLabels()
                }
            )) {
                ForEach(ClipKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Text(clip.kind.note)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if clip.kind == .loop {
                Stepper(
                    value: Binding(
                        get: { clip.loopPasses },
                        set: { newValue in
                            var updated = clip
                            updated.loopPasses = min(max(newValue, 1), 4)
                            state.updateClip(updated)
                        }
                    ),
                    in: 1...4
                ) {
                    Text("B-Durchläufe: \(min(max(clip.loopPasses, 1), 4)) — Datei wird \(String(format: "%.0f", clip.duration * Double(1 + min(max(clip.loopPasses, 1), 4)))) s")
                        .font(.caption)
                }
                .controlSize(.small)
            }

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

            lengthRow
            if clip.kind == .ab {
                switchRows
            }

            Divider()

            abRow(
                title: clip.kind == .loop ? "A (1. Durchlauf)" : "A (vorher)",
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
                title: clip.kind == .loop ? "B (Loop)" : "B (nachher)",
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
                .frame(width: 46, alignment: .leading)
            Text(Timecode.string(
                fromSeconds: seconds,
                rate: state.project.frameRate,
                dropFrame: state.project.dropFrame
            ))
            .timecodeStyle(size: 11)
            Spacer()
            Button("Setzen") { onMark() }
                .controlSize(.mini)
                .help("Aktuelle Position des Abspielkopfs übernehmen")
            Button {
                state.player.seek(to: seconds)
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .controlSize(.mini)
            .help("Abspielkopf hierher setzen")
        }
        .buttonStyle(.bordered)
    }

    private var lengthRow: some View {
        HStack(spacing: 6) {
            Text("Länge")
                .font(.caption)
                .frame(width: 46, alignment: .leading)
            Text(String(format: "%.2f s", clip.duration))
                .timecodeStyle(size: 11)
            Spacer()
        }
    }

    /// The A/B switches. One is the norm and stays a single line; adding more
    /// simply alternates the sides, so no per-segment state has to be shown.
    private var switchRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(clip.switches.enumerated()), id: \.offset) { index, point in
                HStack(spacing: 6) {
                    Text(index.isMultiple(of: 2) ? "A → B" : "B → A")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(index.isMultiple(of: 2) ? Theme.afterTint : Theme.beforeTint)
                        .frame(width: 46, alignment: .leading)
                    Text(Timecode.string(
                        fromSeconds: point,
                        rate: state.project.frameRate,
                        dropFrame: state.project.dropFrame
                    ))
                    .timecodeStyle(size: 11)
                    if clip.usesDefaultSplit {
                        Text("Mitte")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.player.seek(to: point)
                    } label: {
                        Image(systemName: "arrow.right.to.line")
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .help("Abspielkopf hierher setzen")
                }
            }

            HStack(spacing: 6) {
                Button("Wechsel hier") { state.addSwitchAtPlayhead() }
                    .controlSize(.mini)
                    .help("Fügt am Abspielkopf einen weiteren A/B-Wechsel ein")
                Button("Nur einer hier") { state.setSplitToPlayhead() }
                    .controlSize(.mini)
                    .help("Ersetzt alle Wechsel durch einen am Abspielkopf")
                Button("Entfernen") { state.removeSwitchNearestPlayhead() }
                    .controlSize(.mini)
                    .disabled(clip.switches.count < 2)
                Button("Mitte") { state.resetSplitToMiddle() }
                    .controlSize(.mini)
                    .disabled(clip.usesDefaultSplit)
                Spacer()
            }
            .buttonStyle(.bordered)

            if clip.switches.count > 1 {
                Text("\(clip.switches.count) Wechsel — die Seiten wechseln sich ab, beginnend mit A.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .abSection("A/B-Wechsel")
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
                .frame(width: 60, alignment: .leading)
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
        guard let resolved else { return "Standard (—)" }
        return "Standard (\(resolved.name))"
    }

    private var framingControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bildausschnitt verschieben")
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

            Text("Wirkt nur, wenn das Format beschneidet — oben eine Format-Vorschau wählen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
