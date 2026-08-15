import AppKit
import SwiftUI

/// The cover image: one frame grabbed at full resolution, and the title card
/// made from it. Kept separate from the clip export because a still is what
/// leads a post, not part of the cut.
@MainActor
struct StillsPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            grabRow
            if state.grabbedFrame != nil {
                preview
                textFields
                filters
                outputRow
            } else {
                Text("Park the playhead on the frame you want as the cover, then grab it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Cover image")
    }

    private var grabRow: some View {
        HStack(spacing: 6) {
            Button("Grab frame at playhead") { state.grabStill() }
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

    @ViewBuilder
    private var preview: some View {
        if let card = state.titleCardPreview {
            HStack {
                Spacer()
                Image(nsImage: NSImage(cgImage: card, size: .zero))
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
            Text("Preview at \(state.stillPreviewFormat.title) · \(state.stillPreviewFormat.subtitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var textFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Headline", text: state.stillBinding(\.headline), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .lineLimit(1...3)
            TextField("Second line — direction, credits", text: state.stillBinding(\.subline))
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
                label: "Blur",
                value: state.stillBinding(\.blurStrength),
                range: 0...100,
                readout: "\(Int(state.project.stills.blurStrength))"
            )
            slider(
                label: "Darken",
                value: state.stillBinding(\.dimStrength),
                range: 0...0.8,
                readout: "\(Int(state.project.stills.dimStrength * 100)) %"
            )
            Text("Softening the picture is what gives the type somewhere to sit — the tint is then read off the blurred backdrop, not the raw frame.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.mini)
            Text(readout)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Full-resolution frame", isOn: state.stillBinding(\.saveFullFrame))
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Title card per output format", isOn: state.stillBinding(\.saveTitleCards))
                .toggleStyle(.checkbox)
                .font(.caption)

            Picker("File", selection: state.stillBinding(\.fileFormat)) {
                ForEach(StillFileFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
            .controlSize(.small)

            Button("Save images") { state.saveStills() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!state.project.stills.saveFullFrame && !state.project.stills.saveTitleCards)
        }
    }
}
