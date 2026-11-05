import SwiftUI

/// The cut: the post as it will look on the left, what it says and where it
/// goes on the right, the timeline underneath.
@MainActor
struct EditView: View {
    @ObservedObject var store: Store
    @Environment(\.studioStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview
                Rectangle().fill(style.line).frame(width: 1)
                inspector
                    .frame(width: 340)
            }
            StudioHairline()
            TimelineView(store: store)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $store.previewFormat) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button { store.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                Button { store.togglePlay() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                Button { store.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }

                Text(Clock.string(store.currentTime))
                    .font(style.mono(AppType.meta, weight: .medium))
                    .foregroundStyle(style.text)
                    .frame(width: 80, alignment: .trailing)
            }
            .buttonStyle(StudioButtonStyle())
            .controlSize(.small)
            .padding(.horizontal, 14)
            .frame(height: style.barHeight + 6)
            .background(style.panel)

            PlayerSurface(player: store.player)
                .aspectRatio(store.previewFormat.size.width / store.previewFormat.size.height, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
                .background(style.deep)
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filmPanel
                textPanel
                exportPanel
            }
            .padding(14)
        }
        .background(style.bg)
    }

    private var filmPanel: some View {
        Panel("Takes") {
            if store.session.takes.isEmpty {
                Hint("Noch keine Aufnahme. Abspielkopf setzen, Record.")
            }
            ForEach(Array(store.session.takes.enumerated()), id: \.element.id) { index, take in
                HStack(spacing: 8) {
                    Text("\(index + 1)")
                        .font(style.mono(AppType.small, weight: .bold))
                        .foregroundStyle(style.text)
                        .frame(width: 18)
                    Text("\(Clock.string(take.start)) – \(Clock.string(take.end))")
                        .font(style.mono(AppType.small))
                        .foregroundStyle(style.text)
                    Spacer()
                    if let confidence = take.syncConfidence {
                        Text(String(format: "%.0f %%", confidence * 100))
                            .font(style.mono(AppType.small))
                            .foregroundStyle(confidence < 0.4 ? style.warning : style.passed)
                            .help("Übereinstimmung mit dem Filmton")
                    }
                    Button { store.seek(to: take.start) } label: { Image(systemName: "arrow.right.to.line") }
                        .help("Zum Anfang des Takes")
                    Button { store.deleteTake(take.id) } label: { Image(systemName: "trash") }
                        .help("Take aus der Session nehmen (die Dateien bleiben)")
                }
                .buttonStyle(StudioButtonStyle(kind: .quiet))
                .controlSize(.small)
            }

            if store.session.filmURL != nil, store.session.hasTakes {
                HStack(spacing: 6) {
                    Button(store.isSyncing ? "Synchronisiere …" : "Am Originalton syncen") { store.syncAllTakes() }
                        .disabled(store.isSyncing)
                    Spacer()
                    Button { store.nudgeTake(frames: -1) } label: { Image(systemName: "chevron.left") }
                        .help("Take am Abspielkopf ein Bild früher")
                    Button { store.nudgeTake(frames: 1) } label: { Image(systemName: "chevron.right") }
                        .help("Take am Abspielkopf ein Bild später")
                }
                .buttonStyle(StudioButtonStyle())
                .controlSize(.small)
            }
            if store.session.filmURL == nil {
                Hint("Ohne Film bleibt die obere Hälfte leer. «Film …» oben wählt ihn.")
            }
        }
    }

    private var textPanel: some View {
        Panel("Titel im Filmbild") {
            Picker("", selection: $store.session.titleStyle.mode) {
                ForEach(TitleStyle.Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch store.session.titleStyle.mode {
            case .text:
                field("Filmtitel", text: $store.session.title)
                Picker("Schrift", selection: $store.session.titleStyle.face) {
                    ForEach(TitleStyle.Face.allCases) { Text($0.title).tag($0) }
                }
                .controlSize(.small)
            case .image:
                HStack {
                    Text(store.session.titleStyle.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Kein Bild gewählt")
                        .font(style.mono(AppType.small))
                        .foregroundStyle(store.session.titleStyle.imagePath == nil ? style.faint : style.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("PNG wählen …") { store.presentTitleImagePicker() }
                        .buttonStyle(StudioButtonStyle())
                        .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Text("Grösse")
                        .foregroundStyle(style.muted)
                    Slider(value: $store.session.titleStyle.imageScale, in: 0.2...1)
                        .controlSize(.mini)
                    Text("\(Int(store.session.titleStyle.imageScale * 100)) %")
                        .font(style.mono(AppType.small))
                        .foregroundStyle(style.faint)
                        .frame(width: 40, alignment: .trailing)
                }
                field("Filmtitel (für Dateinamen)", text: $store.session.title)
            }

            field("Untertitel, z. B. DIALOGUE CLEAN UP", text: $store.session.subtitle)
            Picker("Lage", selection: $store.session.titleStyle.position) {
                ForEach(TitleStyle.Position.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            StudioHairline(soft: true)
            HStack(spacing: 8) {
                Circle().fill(Tint.original).frame(width: 8, height: 8)
                field("Label A", text: $store.session.labelOriginal)
            }
            HStack(spacing: 8) {
                Circle().fill(Tint.mix).frame(width: 8, height: 8)
                field("Label B", text: $store.session.labelMix)
            }
            Hint("Das Label über Pro Tools wechselt mit dem Ton. Untertitel in Space Mono, Titel in den Hausschriften oder als Original-Titeldesign (PNG mit transparentem Grund).")
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
    }

    private var exportPanel: some View {
        Panel("Export") {
            ForEach(OutputFormat.allCases) { format in
                Toggle(format.title, isOn: Binding(
                    get: { store.session.formats.contains(format) },
                    set: { on in
                        if on { store.session.formats.insert(format) } else { store.session.formats.remove(format) }
                    }
                ))
                .toggleStyle(.checkbox)
            }

            if !store.session.stills.isEmpty {
                StudioHairline(soft: true)
                Text("\(store.session.stills.count) Still\(store.session.stills.count == 1 ? "" : "s")")
                    .font(style.ui(AppType.small + 1, weight: .medium))
                    .foregroundStyle(style.text)
                Toggle("Post-Bild je Format (JPEG)", isOn: $store.session.stillLayout)
                    .toggleStyle(.checkbox)
                Toggle("Filmbild in voller Auflösung (PNG)", isOn: $store.session.stillFilmOriginal)
                    .toggleStyle(.checkbox)
                    .disabled(store.session.filmURL == nil)
                Toggle("Filmbild für Webseite (JPEG, 2560 px)", isOn: $store.session.stillWeb)
                    .toggleStyle(.checkbox)
                    .disabled(store.session.filmURL == nil)
            }

            if store.isExporting {
                ProgressView(value: store.exportProgress).controlSize(.small)
            }
            Button("Exportieren") { store.export() }
                .buttonStyle(StudioButtonStyle(kind: .primary))
                .disabled(store.isExporting || store.session.formats.isEmpty)
                .keyboardShortcut("e", modifiers: .command)
            Hint("Nur zwischen In und Out. Ablage im Ordner «Export» der Session.")
        }
        .font(style.ui(AppType.small + 1))
    }
}
