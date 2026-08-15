import Foundation
import SwiftUI

/// Which inspector the right-hand column is showing.
///
/// Everything used to be stacked in one scroll, which made a seven-card column
/// out of settings that are consulted at four different moments.
enum InspectorTab: String, CaseIterable, Identifiable {
    case clips
    case look
    case cover
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clips: "Clips"
        case .look: "Look"
        case .cover: "Cover"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .clips: "scissors"
        case .look: "paintpalette"
        case .cover: "photo"
        case .export: "square.and.arrow.up"
        }
    }
}

// MARK: - Bindings shared by the inspector panels

extension AppState {
    /// Writes an export setting and re-applies it to the preview, so the look
    /// controls and the burnt-in furniture stay in step with what will be
    /// encoded.
    func exportBinding<Value>(_ keyPath: WritableKeyPath<ExportSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.project.export[keyPath: keyPath] },
            set: { newValue in
                self.project.export[keyPath: keyPath] = newValue
                self.applyPlayerSettings()
            }
        )
    }

    /// Writes a cover-image setting and re-renders its preview.
    func stillBinding<Value>(_ keyPath: WritableKeyPath<StillSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.project.stills[keyPath: keyPath] },
            set: { newValue in
                self.project.stills[keyPath: keyPath] = newValue
                self.refreshTitleCardPreview()
            }
        )
    }
}

// MARK: - Actions the menus drive

extension AppState {
    var hasSelectedClip: Bool { selectedClip != nil }

    func deleteSelectedClip() {
        guard let clip = selectedClip else { return }
        removeClip(clip)
    }

    func snapSelectedClipToHouseLength() {
        guard let clip = selectedClip else { return }
        setLength(project.defaultClipLengthSeconds, for: clip)
    }

    /// Steps through clips in timeline order rather than creation order, which
    /// is what the eye expects when they have been dragged about.
    func selectAdjacentClip(offset: Int) {
        guard !project.clips.isEmpty else { return }
        let ordered = project.clips.sorted { $0.start < $1.start }
        guard let current = ordered.firstIndex(where: { $0.id == selectedClipID }) else {
            selectClip(ordered[0])
            return
        }
        let target = min(max(current + offset, 0), ordered.count - 1)
        selectClip(ordered[target])
    }

    func goToSelectedClipStart() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.start)
    }

    func goToSelectedClipSplit() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.splitTime)
    }

    func goToSelectedClipEnd() {
        guard let clip = selectedClip else { return }
        player.seek(to: clip.end)
    }

    func setPreviewFormat(_ format: SocialFormat?) {
        player.previewFormat = format
        applyPlayerSettings()
    }

    func zoomTimeline(by factor: Double) {
        zoom = min(max(zoom * factor, 1), 400)
    }

    func showInspector(_ tab: InspectorTab) {
        inspectorTab = tab
    }

    /// A one-line summary of where the project stands, for the status bar.
    var summaryLine: String {
        guard project.hasVideo else { return status }
        let enabled = project.clips.filter { $0.isEnabled && $0.duration > 0 }.count
        var parts = ["\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")"]
        if enabled != project.clips.count { parts.append("\(enabled) enabled") }
        parts.append("\(project.audioSources.count) audio")
        if let folder = project.export.outputFolderURL {
            parts.append("→ \(folder.lastPathComponent)")
        }
        return parts.joined(separator: " · ")
    }
}
