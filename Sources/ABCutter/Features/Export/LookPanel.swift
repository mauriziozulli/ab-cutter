import SwiftUI

/// Everything about how the *selected clip* looks: colour, framing, grade,
/// type and texture. Embedded under the clip inspector, because since 0.12
/// the look belongs to the clip — one project can plan an ochre framed A/B
/// and a verdigris full-bleed loop side by side.
@MainActor
struct ClipLookPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            houseSection
            frameSection
            gradeSection
            labelSection
        }
    }

    // MARK: - House style

    private var houseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Farbe", selection: state.lookBinding(\.accent)) {
                ForEach(BrandAccent.allCases) { accent in
                    Text(accent.title).tag(accent)
                }
            }
            .controlSize(.small)
            .help((state.selectedClip?.look.accent ?? .ocker).note)

            Toggle("Zeilen oben und unten", isOn: state.lookBinding(\.showStrips))
                .toggleStyle(.checkbox)
                .help("Mono-Zeile mit harter Linie an beiden Enden — der Rahmen des Aufklebers, aufgeklappt")

            if state.selectedClip?.look.showStrips == true {
                TextField("Oben links — leer nimmt den Filmnamen", text: state.lookBinding(\.stripLeft))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Unten links", text: state.lookBinding(\.stripNote))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Unten rechts — Adresse", text: state.lookBinding(\.stripAddress))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Text("Oben rechts steht die Tonspur, die gerade läuft — sie wechselt mit dem A/B.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            labelledSlider(
                "Korn",
                value: state.lookBinding(\.grainStrength),
                range: 0...0.6,
                readout: "\(Int((state.selectedClip?.look.grainStrength ?? 0) * 100)) %"
            )
            labelledSlider(
                "Schleier",
                value: state.lookBinding(\.vignetteStrength),
                range: 0...0.9,
                readout: "\(Int((state.selectedClip?.look.vignetteStrength ?? 0) * 100)) %"
            )

            if !Typography.housefacesAvailable {
                Label(
                    "Die Hausschriften liessen sich nicht laden — gesetzt wird in Arial Black, Didot und Courier.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .abCard()
        .abSection("Haus-Stil")
    }

    // MARK: - Frame

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Rahmen", selection: state.lookBinding(\.frameTreatment)) {
                ForEach(FrameTreatment.allCases) { treatment in
                    Text(treatment.title).tag(treatment)
                }
            }
            .controlSize(.small)

            Text((state.selectedClip?.look.frameTreatment ?? .insetBoth).note)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if state.selectedClip?.look.frameTreatment != .fullBleed {
                labelledSlider(
                    "Grösse",
                    value: state.lookBinding(\.insetScale),
                    range: 0.6...0.98,
                    readout: "\(Int((state.selectedClip?.look.insetScale ?? 0.86) * 100)) %"
                )

                Picker("Umgebung", selection: state.lookBinding(\.frameBackdrop)) {
                    ForEach(FrameBackdrop.allCases) { backdrop in
                        Text(backdrop.title).tag(backdrop)
                    }
                }
                .controlSize(.small)

                Toggle("Feine Rahmenlinie", isOn: state.lookBinding(\.showFrameBorder))
                    .toggleStyle(.checkbox)
            }

            Picker("Einpassen", selection: state.lookBinding(\.fitMode)) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)
        }
        .abCard()
        .abSection("Rahmen")
    }

    // MARK: - Grade

    private var gradeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("A (vorher)", selection: state.lookBinding(\.beforeLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            Picker("B (nachher)", selection: state.lookBinding(\.afterLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            labelledSlider(
                "Überblende",
                value: state.lookBinding(\.audioCrossfadeMilliseconds),
                range: 0...500,
                readout: "\(Int(state.selectedClip?.look.audioCrossfadeMilliseconds ?? 40)) ms"
            )
        }
        .abCard()
        .abSection("Gradation & Tonwechsel")
    }

    // MARK: - Labels

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Text einbrennen", isOn: state.lookBinding(\.showLabels))
                .toggleStyle(.checkbox)

            if state.selectedClip?.look.showLabels == true {
                HStack(spacing: 6) {
                    TextField("A-Text", text: state.lookBinding(\.beforeLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextField("B-Text", text: state.lookBinding(\.afterLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                TextField("Zweite Zeile — Titel, Regie, Credits", text: state.lookBinding(\.subtitleText))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Picker("Stil", selection: state.lookBinding(\.labelStyle)) {
                    ForEach(LabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .controlSize(.small)

                Picker("Position", selection: state.lookBinding(\.labelPosition)) {
                    ForEach(LabelPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .controlSize(.small)

                Picker("Schatten", selection: state.lookBinding(\.labelShadow)) {
                    ForEach(LabelShadowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help("Automatisch setzt einen weichen Schatten überall dort, wo Schrift direkt auf dem Bild landet")
            }
        }
        .abCard()
        .abSection("Text")
    }

    // MARK: - Helpers

    private func labelledSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readout: String
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .frame(width: 62, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}
