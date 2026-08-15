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
            frameSection
            gradeSection
            labelSection
        }
    }

    // MARK: - Frame

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Frame", selection: state.exportBinding(\.frameTreatment)) {
                ForEach(FrameTreatment.allCases) { treatment in
                    Text(treatment.title).tag(treatment)
                }
            }
            .controlSize(.small)

            if state.project.export.frameTreatment != .fullBleed {
                labelledSlider(
                    "Size",
                    value: state.exportBinding(\.insetScale),
                    range: 0.6...0.98,
                    readout: "\(Int(state.project.export.insetScale * 100)) %"
                )

                Picker("Around", selection: state.exportBinding(\.frameBackdrop)) {
                    ForEach(FrameBackdrop.allCases) { backdrop in
                        Text(backdrop.title).tag(backdrop)
                    }
                }
                .controlSize(.small)

                Toggle("Hairline border", isOn: state.exportBinding(\.showFrameBorder))
                    .toggleStyle(.checkbox)

                Text("The picture snapping out to full bleed at the switch carries the A/B on its own — a scale change reads faster on a phone than a colour change.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Picker("Fit", selection: state.exportBinding(\.fitMode)) {
                ForEach(FitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .controlSize(.small)
        }
        .abCard()
        .abSection("Framing")
    }

    // MARK: - Grade

    private var gradeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Before", selection: state.exportBinding(\.beforeLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            Picker("After", selection: state.exportBinding(\.afterLook)) {
                ForEach(LookStyle.allCases) { look in
                    Text(look.title).tag(look)
                }
            }
            .controlSize(.small)

            labelledSlider(
                "Crossfade",
                value: state.exportBinding(\.audioCrossfadeMilliseconds),
                range: 0...500,
                readout: "\(Int(state.project.export.audioCrossfadeMilliseconds)) ms"
            )
        }
        .abCard()
        .abSection("Grade & audio switch")
    }

    // MARK: - Labels

    private var labelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Burn in labels", isOn: state.exportBinding(\.showLabels))
                .toggleStyle(.checkbox)

            if state.project.export.showLabels {
                HStack(spacing: 6) {
                    TextField("Before", text: state.exportBinding(\.beforeLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    TextField("After", text: state.exportBinding(\.afterLabel))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }

                TextField("Second line — title, direction, credits", text: state.exportBinding(\.subtitleText))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)

                Picker("Style", selection: state.exportBinding(\.labelStyle)) {
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
                    Picker("Shadow", selection: state.exportBinding(\.labelShadow)) {
                        ForEach(LabelShadowMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .help("Auto adds a soft shadow only where the tint would not read against the picture")

                    Text("The tint is read from the colour frame, so a monochrome half still keeps a coloured label.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .abCard()
        .abSection("Labels")
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
