import SwiftUI

/// The stills tab: the markers placed on the timeline, and the one button that
/// renders an image from every one of them.
///
/// Markers are set with + at the playhead and slid along the timeline's marker
/// lane; this list is their other face — jump to one, remove one, read where
/// each lies.
@MainActor
struct MarkerStillsPanel: View {
    @ObservedObject var state: AppState

    @Environment(\.studioStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            markersSection
            outputSection
        }
    }

    // MARK: - Markers

    private var markersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { state.addStillMarkerAtPlayhead() } label: {
                    Label("Still am Abspielkopf", systemImage: "plus")
                }
                .buttonStyle(StudioButtonStyle(kind: .primary))
                .disabled(!state.project.hasVideo)
                .help("Marker setzen (⇧⌘M)")

                Spacer()

                if !state.project.stillMarkers.isEmpty {
                    Button("Alle entfernen") { state.removeAllStillMarkers() }
                        .buttonStyle(StudioButtonStyle(kind: .quiet))
                }
            }

            if state.project.stillMarkers.isEmpty {
                Text("Abspielkopf auf ein Bild stellen und + drücken. Der Marker lässt sich in der Zeitleiste verschieben; gerendert wird aus allen Markern.")
                    .font(style.ui(AppType.small))
                    .foregroundStyle(style.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(state.project.sortedStillMarkers.enumerated()), id: \.element.id) { index, marker in
                        row(index: index, marker: marker)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Marker")
    }

    private func row(index: Int, marker: StillMarker) -> some View {
        let isSelected = marker.id == state.selectedMarkerID
        return HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(style.mono(AppType.small, weight: .bold))
                .foregroundStyle(Brand.tinte.swiftUIColor)
                .frame(width: 20, height: 20)
                .background(Theme.stillTint.opacity(isSelected ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(state.markerTimecode(marker.time))
                .font(style.mono(AppType.meta, weight: .medium))
                .foregroundStyle(style.text)

            Spacer()

            Button { state.removeStillMarker(marker.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(StudioButtonStyle(kind: .quiet))
            .help("Marker entfernen")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(
            isSelected ? style.raised : Color.clear,
            in: RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: style.controlRadius, style: .continuous)
                    .strokeBorder(style.accent, lineWidth: 1)
            }
        }
        .onTapGesture { state.selectStillMarker(marker.id) }
    }

    // MARK: - Output

    private func option(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(style.ui(AppType.small + 1, weight: .medium))
            Text(detail).font(style.ui(AppType.small)).foregroundStyle(style.muted)
        }
    }

    /// What the social crops will be called, e.g. "4:5, 9:16 — JPEG, bis 2× Nenngrösse".
    private var socialSummary: String {
        let formats = state.project.export.formats.map(\.title).joined(separator: ", ")
        return (formats.isEmpty ? "kein Format gewählt" : formats) + " — JPEG, bis 2× Nenngrösse"
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: state.stillBinding(\.markerOriginal)) {
                option("Original", "Volle Filmauflösung, unbearbeitet")
            }
            .toggleStyle(.checkbox)

            if state.project.stills.markerOriginal {
                Picker("Datei", selection: state.stillBinding(\.fileFormat)) {
                    ForEach(StillFileFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                .controlSize(.small)
            }

            Toggle(isOn: state.stillBinding(\.markerWeb)) {
                option("Webseite", "JPEG, lange Kante \(StillExporter.webLongEdge) px, sRGB")
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: state.stillBinding(\.markerSocial)) {
                option("Social Media", socialSummary)
            }
            .toggleStyle(.checkbox)

            Text("Formate wählst du im Export-Tab. Nie hochgerechnet: ein Still ist so scharf wie der Film. Ablage im Zielordner des Exports.")
                .font(style.ui(AppType.small))
                .foregroundStyle(style.muted)
                .fixedSize(horizontal: false, vertical: true)

            if state.isExportingStills {
                ProgressView(value: state.stillExportProgress)
                    .controlSize(.small)
            }

            Button {
                state.renderMarkerStills()
            } label: {
                let count = state.project.stillMarkers.count
                Text(count == 1 ? "1 Still rendern" : "\(count) Stills rendern")
            }
            .buttonStyle(StudioButtonStyle(kind: .primary))
            .disabled(state.project.stillMarkers.isEmpty || state.isExportingStills)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .abCard()
        .abSection("Rendern")
    }
}
