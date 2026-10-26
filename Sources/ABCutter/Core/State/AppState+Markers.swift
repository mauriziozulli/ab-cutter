import AppKit
import Foundation

// MARK: - Still markers
//
// A marker is only a time. The frame behind it is read when the stills are
// rendered, so placing and sliding markers never touches the player's
// composition — a drag can fire as often as it likes.

extension AppState {
    /// The marker nearest to `time` within half a frame, if any. Two markers on
    /// the same frame would render the same image twice.
    private func marker(at time: Double) -> StillMarker? {
        let tolerance = project.frameDuration / 2
        return project.stillMarkers.first { abs($0.time - time) <= tolerance }
    }

    /// Frame-accurate, and inside the picture.
    private func snapped(_ seconds: Double) -> Double {
        let frame = project.frameDuration
        let limit = max(project.videoDurationSeconds - frame, 0)
        let onGrid = (seconds / frame).rounded() * frame
        return min(max(onGrid, 0), limit)
    }

    /// The + button: a marker where the playhead stands.
    func addStillMarkerAtPlayhead() {
        guard project.hasVideo else { return }
        let time = snapped(player.currentTime)
        if let existing = marker(at: time) {
            selectedMarkerID = existing.id
            status = "Hier liegt schon ein Marker."
            return
        }
        let marker = StillMarker(time: time)
        project.stillMarkers.append(marker)
        selectedMarkerID = marker.id
        status = "Marker \(markerNumber(marker.id) ?? 0) bei \(markerTimecode(time)) gesetzt."
    }

    /// Slides a marker. Called many times a second while dragging.
    func moveStillMarker(_ id: UUID, to seconds: Double) {
        guard let index = project.stillMarkers.firstIndex(where: { $0.id == id }) else { return }
        project.stillMarkers[index].time = snapped(seconds)
    }

    func removeStillMarker(_ id: UUID) {
        project.stillMarkers.removeAll { $0.id == id }
        if selectedMarkerID == id { selectedMarkerID = nil }
    }

    func removeSelectedStillMarker() {
        guard let selectedMarkerID else { return }
        removeStillMarker(selectedMarkerID)
    }

    func removeAllStillMarkers() {
        project.stillMarkers.removeAll()
        selectedMarkerID = nil
    }

    /// Selects a marker and parks the playhead on its frame.
    func selectStillMarker(_ id: UUID) {
        guard let marker = project.stillMarkers.first(where: { $0.id == id }) else { return }
        selectedMarkerID = id
        player.seek(to: marker.time)
    }

    /// Previous or next marker relative to the playhead.
    func goToStillMarker(offset: Int) {
        let markers = project.sortedStillMarkers
        guard !markers.isEmpty else { return }
        let now = player.currentTime
        let margin = project.frameDuration / 2
        let target = offset < 0
            ? markers.last { $0.time < now - margin } ?? markers.first
            : markers.first { $0.time > now + margin } ?? markers.last
        if let target { selectStillMarker(target.id) }
    }

    /// One-based position in film order — what the timeline and the file
    /// names call the marker.
    func markerNumber(_ id: UUID) -> Int? {
        project.sortedStillMarkers.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    func markerTimecode(_ seconds: Double) -> String {
        Timecode.string(fromSeconds: seconds, rate: project.frameRate, dropFrame: project.dropFrame)
    }

    // MARK: - Rendering

    /// Reads the frame behind every marker at full resolution, writes one image
    /// each, and — when asked — a contact sheet of all of them.
    func renderMarkerStills() {
        guard let url = project.videoURL else {
            errorMessage = "Zuerst ein Video laden."
            return
        }
        let markers = project.sortedStillMarkers
        guard !markers.isEmpty else {
            errorMessage = "Zuerst Marker setzen: + in der Zeitleiste."
            return
        }
        guard !isExportingStills else { return }
        guard let folder = project.export.outputFolderURL else {
            chooseOutputFolder()
            guard project.export.outputFolderURL != nil else { return }
            renderMarkerStills()
            return
        }

        let settings = project.stills
        let projectName = project.name
        let steps = Double(markers.count + (settings.saveContactSheet ? 1 : 0))
        isExportingStills = true
        stillExportProgress = 0
        status = "Rendere \(markers.count) Still\(markers.count == 1 ? "" : "s") …"

        Task { [weak self] in
            guard let self else { return }
            var thumbnails: [(image: CGImage, label: String)] = []
            var written = 0
            do {
                for (index, marker) in markers.enumerated() {
                    let frame = try await StillExporter.grab(videoURL: url, at: marker.time)
                    let timecode = self.markerTimecode(marker.time)
                    let stamp = timecode
                        .replacingOccurrences(of: ":", with: "-")
                        .replacingOccurrences(of: ";", with: "-")
                    let file = folder.appendingPathComponent(
                        "\(projectName)_still-\(String(format: "%02d", index + 1))_\(stamp).\(settings.fileFormat.fileExtension)"
                    )
                    try StillExporter.write(frame, to: file, as: settings.fileFormat)
                    written += 1

                    if settings.saveContactSheet,
                       let thumb = StillExporter.thumbnail(frame, maxWidth: 960) {
                        thumbnails.append((thumb, "\(index + 1)   \(timecode)"))
                    }
                    self.stillExportProgress = Double(index + 1) / steps
                }

                if settings.saveContactSheet, !thumbnails.isEmpty {
                    guard let sheet = StillExporter.contactSheet(
                        cells: thumbnails,
                        columns: settings.contactSheetColumns,
                        title: projectName
                    ) else { throw StillError.renderFailed }
                    let file = folder.appendingPathComponent(
                        "\(projectName)_stills-uebersicht.\(settings.fileFormat.fileExtension)"
                    )
                    try StillExporter.write(sheet, to: file, as: settings.fileFormat)
                    written += 1
                    self.stillExportProgress = 1
                }
            } catch {
                self.isExportingStills = false
                self.errorMessage = error.localizedDescription
                return
            }

            self.isExportingStills = false
            self.status = "\(written) Bild\(written == 1 ? "" : "er") in \(folder.lastPathComponent) geschrieben."
            self.exportQueue.revealInFinder(folder)
        }
    }
}
