import SwiftUI

/// Everything about how a clip *looks*: how the picture is framed on each side
/// of the switch, the grade, and the burnt-in type.
///
/// Split out of the export panel because these are decided once for a project
/// and then left alone, whereas formats and the output folder are touched on
/// every run.
@MainActor
struct LookPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            houseSection
            frameSection
            safeAreaSection
            gradeSection
            labelSection
        }
    }

    // MARK: - House style

    /// The Sound Matters system: which of the family carries the project, the
    /// two mono strips, and the texture that turns a flat crop into something
    /// that reads as a recording.
    private var houseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Farbe", selection: state.exportBinding(\.accent)) {
                ForEach(BrandAccent.allCases) { accent in
                    Text(accent.title).tag(accent)
                }
            }
            .controlSize(.small)
            .help(state.project.export.accent.note)

            Toggle("Zeilen oben und unten", isOn: state.exportBinding(\.showStrips))
                .toggleStyle(.checkbox)
                .help("Mono-Zeile mit harter Linie an beiden Enden — der Rahmen des Aufklebers, aufgeklappt")

            if state.project.export.showStrips {
                TextField("Oben links — leer nimmt den Filmnamen", text: state.exportBinding(\.stripLeft))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Unten links", text: state.exportBinding(\.stripNote))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                TextField("Unten rechts — Adresse", text: state.exportBinding(\.stripAddress))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Text("Oben rechts steht die Tonspur, die gerade läuft — sie wechselt mit dem A/B.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            labelledSlider(
                "Korn",
                value: state.exportBinding(\.grainStrength),
                range: 0...0.6,
                readout: "\(Int(state.project.export.grainStrength * 100)) %"
            )
            labelledSlider(
                "Schleier",
                value: state.exportBinding(\.vignetteStrength),
                range: 0...0.9,
                readout: "\(Int(state.project.export.vignetteStrength * 100)) %"
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
            Picker("Rahmen", selection: state.exportBinding(\.frameTreatment)) {
                ForEach(FrameTreatment.allCases) { treatment in
                    Text(treatment.title).tag(treatment)
                }
            }
            .controlSize(.small)

            Text(state.project.export.frameTreatment.note)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if state.project.export.frameTreatment != .fullBleed {
                labelledSlider(
                    "Grösse",
                    value: state.exportBinding(\.insetScale),
                    range: 0.6...0.98,
                    readout: "\(Int(state.project.export.insetScale * 100)) %"
                )

                Picker("Umgebung", selection: state.exportBinding(\.frameBackdrop)) {
                    ForEach(FrameBackdrop.allCases) { backdrop in
                        Text(backdrop.title).tag(backdrop)
                    }
                }
                .controlSize(.small)

                Toggle("Feine Rahmenlinie", isOn: state.exportBinding(\.showFrameBorder))
                    .toggleStyle(.checkbox)
            }

            Picker("Einpassen", selection: state.exportBinding(\.fitMode)) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)
        }
        .abCard()
        .abSection("Rahmen")
    }

    // MARK: - Story safe area

    private var safeAreaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Bedienelemente freihalten", isOn: state.exportBinding(\.respectPlayerChrome))
                .toggleStyle(.checkbox)
                .help("Hält Rahmen und Text aus den Streifen heraus, in die Instagram Kontoname und Antwortfeld zeichnet")

            if state.project.export.respectPlayerChrome {
                labelledSlider(
                    "Oben",
                    value: state.exportBinding(\.chromeSafeTop),
                    range: 0...SafeArea.maximum,
                    readout: "\(Int(state.project.export.chromeSafeTop * 100)) %"
                )
                labelledSlider(
                    "Unten",
                    value: state.exportBinding(\.chromeSafeBottom),
                    range: 0...SafeArea.maximum,
                    readout: "\(Int(state.project.export.chromeSafeBottom * 100)) %"
                )

                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .abCard()
        .abSection("Story-Schutzzone (9:16)")
    }

    /// The reserved strips only exist on 9:16, so say so rather than leaving
    /// two sliders that appear to do nothing.
    private var hint: String {
        state.project.export.formats.contains(where: \.hasPlayerChrome)
            ? "Gilt nur für 9:16 — ein Beitrag im Feed hat keine Bedienelemente über dem Bild. Im Vorschauformat 9:16 markieren gestrichelte Linien die Streifen; exportiert werden sie nie."
            : "Gilt nur für 9:16. Dieses Format ist gerade nicht ausgewählt."
    }

    // MARK: - Grade

    private var gradeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("A (vorher)", selection: state.exportBinding(\.beforeLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            Picker("B (nachher)", selection: state.exportBinding(\.afterLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            labelledSlider(
                "Überblende",
                value: state.exportBinding(\.audioCrossfadeMilliseconds),
                range: 0...500,
                readout: "\(Int(state.project.export.audioCrossfadeMilliseconds)) ms"
            )
        }
        .abCard()
        .abSection("Gradation & Tonwechsel")
    }

    // MARK: - Labels

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Text einbrennen", isOn: state.exportBinding(\.showLabels))
                .toggleStyle(.checkbox)

            if state.project.export.showLabels {
                HStack(spacing: 6) {
                    TextField("A-Text", text: state.exportBinding(\.beforeLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextField("B-Text", text: state.exportBinding(\.afterLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                TextField("Zweite Zeile — Titel, Regie, Credits", text: state.exportBinding(\.subtitleText))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Picker("Stil", selection: state.exportBinding(\.labelStyle)) {
                    ForEach(LabelStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .controlSize(.small)

                Picker("Position", selection: state.exportBinding(\.labelPosition)) {
                    ForEach(LabelPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .controlSize(.small)

                if state.project.export.labelStyle == .tinted {
                    Picker("Schatten", selection: state.exportBinding(\.labelShadow)) {
                        ForEach(LabelShadowMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .help("Automatisch setzt einen weichen Schatten nur dort, wo die Farbe gegen das Bild nicht lesbar wäre")

                    Text("Die Farbe wird aus dem Farbbild gelesen — auch eine Schwarzweiss-Hälfte behält so farbigen Text.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
