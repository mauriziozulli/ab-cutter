import AppKit
import SwiftUI

/// The selected clip's look. The design itself is fixed — framed picture over
/// a blurred backdrop, colour video, one small type style — so what remains
/// here is what actually varies from clip to clip: the two side colours, the
/// texts, and a few quiet dials.
@MainActor
struct ClipLookPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            colourSection
            textSection
            stripsSection
            fineSection
        }
    }

    // MARK: - The two colours

    private var colourSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            colourRow(label: "A (vorher)", keyPath: \.beforeColor)
            colourRow(label: "B (nachher)", keyPath: \.afterColor)

            Text("Rahmen und Schrift einer Seite tragen dieselbe Farbe — der Wechsel liest sich dann als ein Ereignis. Weiss für A und Blau für B ist z. B. ein Klick auf das Feld.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .abCard()
        .abSection("Farben")
    }

    private func colourRow(
        label: String,
        keyPath: WritableKeyPath<ClipLook, RGBColor>
    ) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .frame(width: 68, alignment: .leading)

            ForEach(RGBColor.swatches, id: \.name) { swatch in
                Button {
                    state.lookBinding(keyPath).wrappedValue = swatch.colour
                } label: {
                    Circle()
                        .fill(Color(red: swatch.colour.red, green: swatch.colour.green, blue: swatch.colour.blue))
                        .frame(width: 15, height: 15)
                        .overlay(
                            Circle().strokeBorder(
                                isCurrent(swatch.colour, keyPath: keyPath) ? Color.primary : Theme.hairline,
                                lineWidth: isCurrent(swatch.colour, keyPath: keyPath) ? 2 : 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help(swatch.name)
            }

            ColorPicker("", selection: colourBinding(keyPath), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .help("Eigene Farbe")

            Spacer()
        }
    }

    private func isCurrent(_ colour: RGBColor, keyPath: WritableKeyPath<ClipLook, RGBColor>) -> Bool {
        guard let current = state.selectedClip?.look[keyPath: keyPath] else { return false }
        return abs(current.red - colour.red) < 0.004
            && abs(current.green - colour.green) < 0.004
            && abs(current.blue - colour.blue) < 0.004
    }

    /// SwiftUI colour in, plain RGB out. The picker hands back whatever space
    /// the user chose in, so the components are read through sRGB.
    private func colourBinding(_ keyPath: WritableKeyPath<ClipLook, RGBColor>) -> Binding<Color> {
        Binding(
            get: {
                let colour = state.selectedClip?.look[keyPath: keyPath] ?? .white
                return Color(red: colour.red, green: colour.green, blue: colour.blue)
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                state.lookBinding(keyPath).wrappedValue = RGBColor(
                    red: Double(srgb.redComponent),
                    green: Double(srgb.greenComponent),
                    blue: Double(srgb.blueComponent)
                )
            }
        )
    }

    // MARK: - Text

    private var textSection: some View {
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
            }
        }
        .abCard()
        .abSection("Text")
    }

    // MARK: - Strips

    private var stripsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Zeilen oben und unten", isOn: state.lookBinding(\.showStrips))
                .toggleStyle(.checkbox)
                .help("Mono-Zeile mit harter Linie an beiden Enden")

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
        }
        .abCard()
        .abSection("Zeilen")
    }

    // MARK: - The quiet dials

    private var fineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            labelledSlider(
                "Grösse",
                value: state.lookBinding(\.insetScale),
                range: 0.6...0.98,
                readout: "\(Int((state.selectedClip?.look.insetScale ?? 0.86) * 100)) %"
            )

            Picker("Einpassen", selection: state.lookBinding(\.fitMode)) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)

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
            labelledSlider(
                "Überblende",
                value: state.lookBinding(\.audioCrossfadeMilliseconds),
                range: 0...500,
                readout: "\(Int(state.selectedClip?.look.audioCrossfadeMilliseconds ?? 40)) ms"
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
        .abSection("Rahmen & Textur")
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
                .frame(width: 68, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}
