import AppKit
import SwiftUI

/// The two cards around a post: the title image that leads it and the end card
/// that closes it. Kept separate from the clip export because a still is not
/// part of the cut.
@MainActor
struct StillsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            titleSection
            endSection
            outputSection
        }
    }

    // MARK: - Title card

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            grabRow
            if state.grabbedFrame != nil {
                card(state.titleCardPreview)
                textFields
                filters
            } else {
                Text("Abspielkopf auf das gewünschte Bild stellen und greifen.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Titelbild")
    }

    private var grabRow: some View {
        HStack(spacing: 6) {
            Button("Bild am Abspielkopf greifen") { state.grabStill() }
                .controlSize(.small)
                .disabled(!state.project.hasVideo)
            Spacer()
            if let frame = state.grabbedFrame {
                Text("\(frame.width)×\(frame.height)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Überschrift", text: state.stillBinding(\.headline), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .lineLimit(1...3)
            TextField("Zweite Zeile — Regie, Credits", text: state.stillBinding(\.subline))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Picker("Text", selection: state.stillBinding(\.textPosition)) {
                ForEach(StillTextPosition.allCases) { position in
                    Text(position.title).tag(position)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            slider(
                label: "Weichzeichnen",
                value: state.stillBinding(\.blurStrength),
                range: 0...100,
                readout: "\(Int(state.project.stills.blurStrength))"
            )
            slider(
                label: "Abdunkeln",
                value: state.stillBinding(\.dimStrength),
                range: 0...0.8,
                readout: "\(Int(state.project.stills.dimStrength * 100)) %"
            )
            Text(state.project.export.labelStyle.isHouse
                 ? "Das Weichzeichnen schafft den Platz für den Text. Die Farben kommen im Haus-Stil aus der Palette, nicht aus dem Bild."
                 : "Das Weichzeichnen schafft erst den Platz für den Text — die Farbe wird danach aus dem unscharfen Hintergrund gelesen, nicht aus dem Rohbild.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - End card

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Abspannbild je Ausgabeformat", isOn: state.stillBinding(\.saveEndCard))
                .toggleStyle(.checkbox)
                .font(.caption)

            if state.project.stills.saveEndCard {
                card(state.endCardPreview)

                HStack(spacing: 6) {
                    TextField("Erste Zeile", text: state.stillBinding(\.endWordmarkTop))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextField("Im Balken", text: state.stillBinding(\.endWordmarkBar))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                TextField("Adresse", text: state.stillBinding(\.endAddress))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Zusatz — Credit, was zu hören war", text: state.stillBinding(\.endNote))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Picker("Grund", selection: state.stillBinding(\.endGround)) {
                    ForEach(EndCardGround.allCases) { ground in
                        Text(ground.title).tag(ground)
                    }
                }
                .controlSize(.small)

                Text("Der Wortlaut steht wie auf dem Aufkleber: erste Zeile frei, zweite im Balken. Auf Tinte braucht das Abspannbild kein Standbild.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Abspann")
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Bild in voller Auflösung", isOn: state.stillBinding(\.saveFullFrame))
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Titelbild je Ausgabeformat", isOn: state.stillBinding(\.saveTitleCards))
                .toggleStyle(.checkbox)
                .font(.caption)

            Picker("Datei", selection: state.stillBinding(\.fileFormat)) {
                ForEach(StillFileFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .controlSize(.small)

            Button("Bilder sichern") { state.saveStills() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!wantsAnything)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Sichern")
    }

    private var wantsAnything: Bool {
        let stills = state.project.stills
        return stills.saveFullFrame || stills.saveTitleCards || stills.saveEndCard
    }

    // MARK: - Helpers

    @ViewBuilder
    private func card(_ image: CGImage?) -> some View {
        if let image {
            HStack {
                Spacer()
                Image(nsImage: NSImage(cgImage: image, size: .zero))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                Spacer()
            }
            Text("Vorschau in \(state.stillPreviewFormat.title) · \(state.stillPreviewFormat.subtitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func slider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}
