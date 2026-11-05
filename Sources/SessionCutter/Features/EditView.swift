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
                sessionPanel
            }
            .padding(14)
        }
        .background(style.bg)
    }

    private var filmPanel: some View {
        Panel("Film") {
            HStack {
                Text(store.session.filmURL?.lastPathComponent ?? "Kein Film")
                    .font(style.mono(AppType.small))
                    .foregroundStyle(store.session.filmURL == nil ? style.faint : style.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Wählen …") { store.presentFilmPicker() }
                    .buttonStyle(StudioButtonStyle())
                    .controlSize(.small)
            }
            if store.session.filmURL != nil {
                HStack(spacing: 6) {
                    Button(store.isSyncing ? "Synchronisiere …" : "Am Originalton syncen") { store.syncFilm() }
                        .buttonStyle(StudioButtonStyle())
                        .disabled(store.isSyncing)
                    Spacer()
                    Button { store.nudgeFilm(frames: -1) } label: { Image(systemName: "chevron.left") }
                        .help("Film ein Bild früher")
                    Button { store.nudgeFilm(frames: 1) } label: { Image(systemName: "chevron.right") }
                        .help("Film ein Bild später")
                }
                .buttonStyle(StudioButtonStyle())
                .controlSize(.small)

                if let confidence = store.session.syncConfidence {
                    Hint(String(
                        format: "Versatz %+.2f s · Übereinstimmung %.0f %%%@",
                        store.session.filmOffset,
                        confidence * 100,
                        confidence < 0.4 ? " — bitte prüfen" : ""
                    ))
                } else {
                    Hint(String(format: "Versatz %+.2f s · noch nicht gesynct", store.session.filmOffset))
                }
            }
        }
    }

    private var textPanel: some View {
        Panel("Text") {
            field("Filmtitel", text: $store.session.title)
            field("Untertitel, z. B. DIALOGUE CLEAN UP", text: $store.session.subtitle)
            HStack(spacing: 8) {
                Circle().fill(Tint.original).frame(width: 8, height: 8)
                field("Label A", text: $store.session.labelOriginal)
            }
            HStack(spacing: 8) {
                Circle().fill(Tint.mix).frame(width: 8, height: 8)
                field("Label B", text: $store.session.labelMix)
            }
            Hint("Der Titel steht im Filmbild oben, das Label wechselt mit dem Ton über Pro Tools.")
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

    private var sessionPanel: some View {
        Panel("Session") {
            HStack {
                Button("Neue Aufnahme") { store.enterRecordPhase() }
                Button("Öffnen …") { store.presentOpenSession() }
                Spacer()
                Button { store.revealFolder() } label: { Image(systemName: "folder") }
                    .help("Session-Ordner im Finder zeigen")
            }
            .buttonStyle(StudioButtonStyle())
            .controlSize(.small)
        }
    }
}
